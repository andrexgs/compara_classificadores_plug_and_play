"""Smoke tests for the clfbench package structure and CLI diagnostics."""

from __future__ import annotations

import importlib
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import clfbench
from clfbench.cli import collect_doctor_report, main

SUBPACKAGES: tuple[str, ...] = (
    "clfbench.config",
    "clfbench.data",
    "clfbench.augmentation",
    "clfbench.models",
    "clfbench.optim",
    "clfbench.training",
    "clfbench.evaluation",
    "clfbench.active_learning",
    "clfbench.distillation",
    "clfbench.xai",
    "clfbench.oneclass",
    "clfbench.reporting",
    "clfbench.utils",
)


class SmokeTestSuite(unittest.TestCase):
    """Core smoke test suite compatible with both pytest and unittest."""

    def test_package_version_exposed(self) -> None:
        """Verify that clfbench exposes a valid __version__ string."""
        self.assertTrue(hasattr(clfbench, "__version__"))
        self.assertIsInstance(clfbench.__version__, str)
        self.assertEqual(clfbench.__version__, "0.1.0")

    def test_all_subpackages_import_cleanly(self) -> None:
        """Verify that every subpackage imports and has a module docstring."""
        for module_name in SUBPACKAGES:
            with self.subTest(module=module_name):
                module = importlib.import_module(module_name)
                self.assertIsNotNone(module.__doc__)
                self.assertTrue(str(module.__doc__).strip())

    def test_cli_help_exits_zero(self) -> None:
        """Verify that `clfbench --help` exits with code 0."""
        with self.assertRaises(SystemExit) as ctx:
            main(["--help"])
        self.assertEqual(ctx.exception.code, 0)

    def test_cli_version_exits_zero(self) -> None:
        """Verify that `clfbench --version` exits with code 0."""
        with self.assertRaises(SystemExit) as ctx:
            main(["--version"])
        self.assertEqual(ctx.exception.code, 0)

    def test_cli_doctor_succeeds_on_cpu_fallback(self) -> None:
        """Verify that `clfbench doctor` exits 0 when running on CPU fallback."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            base = Path(tmp_dir)
            data_dir = base / "data"
            output_dir = base / "outputs"
            data_dir.mkdir()
            output_dir.mkdir()

            with mock.patch.dict(os.environ, {"CLFBENCH_FORCE_CPU": "1"}):
                exit_code = main(
                    [
                        "doctor",
                        "--data-dir",
                        str(data_dir),
                        "--output-dir",
                        str(output_dir),
                    ]
                )
                self.assertEqual(exit_code, 0)

                report = collect_doctor_report(data_dir=data_dir, output_dir=output_dir)
                self.assertFalse(report.cuda_available)
                self.assertTrue(report.is_healthy)
                self.assertTrue(
                    any("CPU" in warning for warning in report.warnings),
                    msg=f"Expected CPU fallback warning in {report.warnings}",
                )

    def test_cli_doctor_fails_when_outputs_missing_or_unwritable(self) -> None:
        """Verify that `clfbench doctor` returns non-zero on missing/unwritable outputs."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            base = Path(tmp_dir)
            data_dir = base / "data"
            missing_output = base / "nonexistent_outputs"
            data_dir.mkdir()

            exit_code = main(
                [
                    "doctor",
                    "--data-dir",
                    str(data_dir),
                    "--output-dir",
                    str(missing_output),
                ]
            )
            self.assertNotEqual(exit_code, 0)

            if os.geteuid() != 0:
                ro_output = base / "readonly_outputs"
                ro_output.mkdir()
                ro_output.chmod(stat.S_IREAD | stat.S_IXUSR)
                try:
                    ro_code = main(
                        [
                            "doctor",
                            "--data-dir",
                            str(data_dir),
                            "--output-dir",
                            str(ro_output),
                        ]
                    )
                    self.assertNotEqual(ro_code, 0)
                finally:
                    ro_output.chmod(stat.S_IRWXU)

    def test_cli_module_execution_in_subprocess(self) -> None:
        """Verify subprocess invocation of `python -m clfbench.cli doctor` on CPU."""
        env = os.environ.copy()
        src_path = str(Path(__file__).resolve().parents[1] / "src")
        env["PYTHONPATH"] = (
            f"{src_path}{os.pathsep}{env['PYTHONPATH']}" if "PYTHONPATH" in env else src_path
        )
        env["CLFBENCH_FORCE_CPU"] = "1"

        help_proc = subprocess.run(
            [sys.executable, "-m", "clfbench.cli", "--help"],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(help_proc.returncode, 0, msg=help_proc.stderr)
        self.assertIn("doctor", help_proc.stdout)

        doctor_proc = subprocess.run(
            [sys.executable, "-m", "clfbench.cli", "doctor"],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(doctor_proc.returncode, 0, msg=doctor_proc.stderr)
        self.assertIn("STATUS: OK", doctor_proc.stdout)


if __name__ == "__main__":
    unittest.main()
