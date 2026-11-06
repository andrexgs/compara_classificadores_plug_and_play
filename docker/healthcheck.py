"""Docker container healthcheck script for clfbench.

Verifies that the `clfbench` package imports cleanly and that environment
health requirements (such as writable `/outputs`) are satisfied.
"""

from __future__ import annotations

import logging
import sys

from clfbench.cli import collect_doctor_report

logger = logging.getLogger(__name__)


def run_healthcheck() -> int:
    """Execute a lightweight container healthcheck.

    Returns:
        Exit status code (`0` when healthy, `1` when unhealthy).
    """
    logging.basicConfig(
        level=logging.WARNING,
        format="%(asctime)s | %(levelname)-8s | %(name)s | %(message)s",
    )
    try:
        report = collect_doctor_report()
    except Exception as exc:  # pragma: no cover
        logger.error("Healthcheck failed with unexpected exception: %s", exc)
        return 1

    if not report.is_healthy:
        for err in report.errors:
            logger.error("Healthcheck error: %s", err)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(run_healthcheck())
