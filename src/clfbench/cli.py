"""Command-line interface for the clfbench framework.

Provides top-level CLI entrypoints including `--version`, `--help`, and the
`doctor` subcommand for environment and hardware diagnostics.
"""

from __future__ import annotations

import argparse
import getpass
import logging
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

from clfbench import __version__

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class PathStatus:
    """Diagnostic status for a filesystem path.

    Attributes:
        label: Logical path label (e.g. `/data` or `/outputs`).
        resolved_path: Actual filesystem path inspected.
        exists: Whether the path exists on disk.
        readable: Whether the current process has read access.
        writable: Whether the current process has write access.
        free_gb: Free disk space in GiB for the underlying mount.
        total_gb: Total disk space in GiB for the underlying mount.
    """

    label: str
    resolved_path: Path
    exists: bool
    readable: bool
    writable: bool
    free_gb: float
    total_gb: float


@dataclass(frozen=True)
class DoctorReport:
    """Aggregated environment diagnostic report for `clfbench doctor`.

    Attributes:
        clfbench_version: Installed version of `clfbench`.
        python_version: Active Python interpreter version string.
        platform_info: Operating system and kernel summary.
        torch_version: Installed PyTorch version string (or `"not installed"`).
        cuda_available: Whether CUDA is usable by PyTorch.
        cuda_version: CUDA runtime version reported by PyTorch, if any.
        gpu_names: List of detected GPU device names.
        uid: Effective user ID of the running process.
        gid: Effective group ID of the running process.
        username: Resolved username of the running process.
        git_commit: Short git commit SHA or `"unknown"`.
        shm_total_gb: Total `/dev/shm` size in GiB, if available.
        shm_free_gb: Free `/dev/shm` size in GiB, if available.
        data_status: Path diagnostic for `/data`.
        output_status: Path diagnostic for `/outputs`.
        warnings: Non-critical warnings collected during inspection.
        errors: Critical errors that cause a non-zero exit code.
    """

    clfbench_version: str
    python_version: str
    platform_info: str
    torch_version: str
    cuda_available: bool
    cuda_version: str
    gpu_names: list[str]
    uid: int
    gid: int
    username: str
    git_commit: str
    shm_total_gb: float | None
    shm_free_gb: float | None
    data_status: PathStatus
    output_status: PathStatus
    warnings: list[str]
    errors: list[str]

    @property
    def is_healthy(self) -> bool:
        """Return True if no critical errors were found."""
        return len(self.errors) == 0


def _configure_logging(level: int = logging.INFO) -> None:
    """Configure standard logging for CLI execution.

    Args:
        level: Logging verbosity level.
    """
    logging.basicConfig(
        level=level,
        format="%(asctime)s | %(levelname)-8s | %(name)s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )


def _resolve_target_path(default_container_path: str, env_var: str, local_fallback: str) -> Path:
    """Resolve a target directory path across container and native environments.

    If `env_var` is explicitly set, that path is used. Otherwise, if
    `default_container_path` exists on the filesystem (standard inside Docker),
    it is used directly. When running natively on a host where `/data` or
    `/outputs` does not exist at `/`, `local_fallback` is used.

    Args:
        default_container_path: Standard path inside the container (e.g. `/outputs`).
        env_var: Environment variable name allowing explicit override.
        local_fallback: Relative fallback path for native host execution.

    Returns:
        Resolved `Path` object.
    """
    override = os.environ.get(env_var)
    if override:
        return Path(override).expanduser().resolve()

    container_path = Path(default_container_path)
    if container_path.exists() or Path("/.dockerenv").exists():
        return container_path

    return Path(local_fallback).resolve()


def _check_writable(path: Path) -> bool:
    """Test whether a directory is genuinely writable by the current user.

    Args:
        path: Directory path to test.

    Returns:
        True if a temporary file can be created and removed in `path`, or if
        `os.access(path, os.W_OK)` succeeds for non-directory paths.
    """
    if not path.exists():
        return False
    if not path.is_dir():
        return os.access(path, os.W_OK)
    try:
        with tempfile.NamedTemporaryFile(dir=path, prefix=".clfbench_probe_", delete=True):
            return True
    except OSError:
        return False


def _inspect_path(label: str, path: Path) -> PathStatus:
    """Collect existence, permission, and disk usage details for a path.

    Args:
        label: Display label for the path (e.g. `/data` or `/outputs`).
        path: Resolved filesystem path to inspect.

    Returns:
        Populated `PathStatus` instance.
    """
    exists = path.exists()
    readable = os.access(path, os.R_OK) if exists else False
    writable = _check_writable(path) if exists else False

    probe_target = path if exists else path.parent
    free_gb = 0.0
    total_gb = 0.0
    try:
        usage = shutil.disk_usage(probe_target)
        free_gb = usage.free / (1024**3)
        total_gb = usage.total / (1024**3)
    except OSError:
        logger.debug("Could not query disk usage for %s", probe_target)

    return PathStatus(
        label=label,
        resolved_path=path,
        exists=exists,
        readable=readable,
        writable=writable,
        free_gb=free_gb,
        total_gb=total_gb,
    )


def _get_git_commit() -> str:
    """Retrieve the current git commit hash from environment or repository.

    Returns:
        Short commit hash string or `"unknown"` when unavailable.
    """
    for env_key in ("CLFBENCH_GIT_COMMIT", "VCS_REF", "GIT_COMMIT"):
        val = os.environ.get(env_key, "").strip()
        if val and val.lower() != "unknown":
            return val

    try:
        result = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
            timeout=2.0,
        )
        commit = result.stdout.strip()
        return commit if commit else "unknown"
    except (subprocess.SubprocessError, FileNotFoundError, OSError):
        return "unknown"


def _get_user_info() -> tuple[int, int, str]:
    """Return effective UID, GID, and username of the current process.

    Returns:
        Tuple of `(uid, gid, username)`.
    """
    uid = os.getuid() if hasattr(os, "getuid") else -1
    gid = os.getgid() if hasattr(os, "getgid") else -1
    try:
        username = getpass.getuser()
    except Exception:  # pragma: no cover - fallback for unmapped container UIDs
        username = f"uid_{uid}"
    return uid, gid, username


def _inspect_shm() -> tuple[float | None, float | None]:
    """Inspect `/dev/shm` shared memory capacity if present on the OS.

    Returns:
        Tuple `(total_gb, free_gb)` in GiB, or `(None, None)` if `/dev/shm` is unavailable.
    """
    shm_path = Path("/dev/shm")
    if not shm_path.exists():
        return None, None
    try:
        usage = shutil.disk_usage(shm_path)
        return usage.total / (1024**3), usage.free / (1024**3)
    except OSError:
        return None, None


def _inspect_torch() -> tuple[str, bool, str, list[str]]:
    """Inspect PyTorch installation and CUDA/GPU availability.

    Returns:
        Tuple `(torch_version, cuda_available, cuda_version, gpu_names)`.
    """
    try:
        import torch  # type: ignore[import-not-found]
    except ImportError:
        return "not installed", False, "N/A", []

    torch_version = str(getattr(torch, "__version__", "unknown"))
    cuda_version = str(getattr(torch.version, "cuda", None) or "N/A")

    force_cpu = os.environ.get("CLFBENCH_FORCE_CPU", "0").strip() == "1"
    cuda_available = False if force_cpu else bool(torch.cuda.is_available())
    gpu_names: list[str] = []

    if cuda_available:
        try:
            device_count = int(torch.cuda.device_count())
            for idx in range(device_count):
                gpu_names.append(str(torch.cuda.get_device_name(idx)))
        except Exception as exc:  # pragma: no cover
            logger.debug("Failed to query CUDA device names: %s", exc)

    return torch_version, cuda_available, cuda_version, gpu_names


def collect_doctor_report(
    data_dir: Path | None = None,
    output_dir: Path | None = None,
) -> DoctorReport:
    """Gather all system, hardware, and filesystem diagnostics.

    Args:
        data_dir: Optional explicit path for the data directory.
        output_dir: Optional explicit path for the outputs directory.

    Returns:
        Populated `DoctorReport` object.
    """
    warnings: list[str] = []
    errors: list[str] = []

    resolved_data = data_dir or _resolve_target_path("/data", "CLFBENCH_DATA_DIR", "./data")
    resolved_output = output_dir or _resolve_target_path(
        "/outputs", "CLFBENCH_OUTPUT_DIR", "./outputs"
    )

    data_status = _inspect_path("/data", resolved_data)
    output_status = _inspect_path("/outputs", resolved_output)

    torch_version, cuda_available, cuda_version, gpu_names = _inspect_torch()
    if torch_version == "not installed":
        warnings.append(
            "PyTorch ('torch') is not installed in the active Python environment."
        )
    if not cuda_available:
        warnings.append(
            "No CUDA GPU detected or enabled. Falling back to CPU execution mode."
        )

    if not data_status.exists:
        warnings.append(
            f"Data directory /data ({data_status.resolved_path}) does not exist."
        )
    elif not data_status.readable:
        warnings.append(
            f"Data directory /data ({data_status.resolved_path}) is not readable."
        )

    if not output_status.exists:
        errors.append(
            f"Critical: Output directory /outputs ({output_status.resolved_path}) does not exist."
        )
    elif not output_status.writable:
        errors.append(
            f"Critical: Output directory /outputs ({output_status.resolved_path}) is not writable "
            "by the current user."
        )

    shm_total_gb, shm_free_gb = _inspect_shm()
    if shm_total_gb is not None and shm_total_gb < 1.0:
        warnings.append(
            f"Shared memory (/dev/shm) is small ({shm_total_gb:.2f} GiB). "
            "PyTorch DataLoaders with num_workers > 0 may fail; consider shm_size >= 8gb."
        )

    uid, gid, username = _get_user_info()
    git_commit = _get_git_commit()

    return DoctorReport(
        clfbench_version=__version__,
        python_version=platform.python_version(),
        platform_info=f"{platform.system()} {platform.release()} ({platform.machine()})",
        torch_version=torch_version,
        cuda_available=cuda_available,
        cuda_version=cuda_version,
        gpu_names=gpu_names,
        uid=uid,
        gid=gid,
        username=username,
        git_commit=git_commit,
        shm_total_gb=shm_total_gb,
        shm_free_gb=shm_free_gb,
        data_status=data_status,
        output_status=output_status,
        warnings=warnings,
        errors=errors,
    )


def format_doctor_report(report: DoctorReport) -> str:
    """Format a `DoctorReport` into a human-readable diagnostic table.

    Args:
        report: Collected `DoctorReport`.

    Returns:
        Multi-line formatted report string.
    """
    gpu_summary = (
        ", ".join(f"[{i}] {name}" for i, name in enumerate(report.gpu_names))
        if report.gpu_names
        else "None (CPU fallback active)"
    )
    shm_summary = (
        f"{report.shm_free_gb:.2f} GiB free / {report.shm_total_gb:.2f} GiB total"
        if report.shm_total_gb is not None and report.shm_free_gb is not None
        else "N/A (not mounted)"
    )

    data_perms = (
        f"exists={report.data_status.exists}, "
        f"read={report.data_status.readable}, "
        f"write={report.data_status.writable}"
    )
    output_perms = (
        f"exists={report.output_status.exists}, "
        f"read={report.output_status.readable}, "
        f"write={report.output_status.writable}"
    )

    lines = [
        "=" * 76,
        f"clfbench doctor (v{report.clfbench_version}) - Environment Diagnostics",
        "=" * 76,
        f"  Python Version    : {report.python_version} ({sys.executable})",
        f"  Platform          : {report.platform_info}",
        f"  User (UID:GID)    : {report.username} ({report.uid}:{report.gid})",
        f"  Git Commit        : {report.git_commit}",
        "-" * 76,
        f"  PyTorch Version   : {report.torch_version} (CUDA build: {report.cuda_version})",
        f"  CUDA Available    : {report.cuda_available}",
        f"  GPU Device(s)     : {gpu_summary}",
        f"  Compute Mode      : {'GPU (CUDA)' if report.cuda_available else 'CPU (Fallback)'}",
        "-" * 76,
        f"  Path /data        : {report.data_status.resolved_path} ({data_perms})",
        f"  Path /outputs     : {report.output_status.resolved_path} ({output_perms})",
        (
            f"  Disk (/outputs)   : {report.output_status.free_gb:.2f} GiB free / "
            f"{report.output_status.total_gb:.2f} GiB total"
        ),
        f"  Shared Mem (/shm) : {shm_summary}",
        "=" * 76,
    ]

    if report.warnings:
        lines.append("WARNINGS:")
        for warning in report.warnings:
            lines.append(f"  [WARN] {warning}")
        lines.append("-" * 76)

    if report.errors:
        lines.append("CRITICAL ERRORS:")
        for err in report.errors:
            lines.append(f"  [ERROR] {err}")
        lines.append("=" * 76)
        lines.append("STATUS: FAILED (critical environment issues detected)")
    else:
        lines.append("STATUS: OK (environment ready)")

    return "\n".join(lines)


def _emit_doctor_output(text: str) -> None:
    """Output the formatted `doctor` report using `rich` when available.

    Args:
        text: Formatted diagnostic text to display.
    """
    try:
        from rich.console import Console  # type: ignore[import-not-found]

        console = Console(highlight=False, markup=False, soft_wrap=True)
        console.print(text)
    except ImportError:
        sys.stdout.write(text + "\n")
        sys.stdout.flush()


def run_doctor(data_dir: Path | None = None, output_dir: Path | None = None) -> int:
    """Execute the `doctor` diagnostic subcommand.

    Args:
        data_dir: Optional override for `/data` directory inspection.
        output_dir: Optional override for `/outputs` directory inspection.

    Returns:
        Exit code (`0` when healthy, `1` on critical errors).
    """
    report = collect_doctor_report(data_dir=data_dir, output_dir=output_dir)
    formatted = format_doctor_report(report)
    _emit_doctor_output(formatted)
    return 0 if report.is_healthy else 1


def build_parser() -> argparse.ArgumentParser:
    """Construct the root `argparse.ArgumentParser` for `clfbench`.

    Returns:
        Configured `ArgumentParser` instance.
    """
    parser = argparse.ArgumentParser(
        prog="clfbench",
        description=(
            "clfbench: Plug-and-play benchmark framework for PyTorch image classifiers."
        ),
    )
    parser.add_argument(
        "-V",
        "--version",
        action="version",
        version=f"clfbench {__version__}",
        help="Show the clfbench version and exit.",
    )

    subparsers = parser.add_subparsers(dest="command", metavar="<command>")

    doctor_parser = subparsers.add_parser(
        "doctor",
        help="Run environment, hardware (CUDA/CPU), and filesystem diagnostics.",
        description="Inspect Python, PyTorch, GPU/CPU availability, /data, /outputs, and /dev/shm.",
    )
    doctor_parser.add_argument(
        "--data-dir",
        type=Path,
        default=None,
        help="Explicit path to inspect for /data (defaults to /data or ./data).",
    )
    doctor_parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
        help="Explicit path to inspect for /outputs (defaults to /outputs or ./outputs).",
    )

    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Main CLI entrypoint for `clfbench`.

    Args:
        argv: Optional sequence of command-line arguments. Defaults to `sys.argv[1:]`.

    Returns:
        Process exit status code (`0` on success, non-zero on error).
    """
    _configure_logging()
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.command == "doctor":
        return run_doctor(data_dir=args.data_dir, output_dir=args.output_dir)

    parser.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
