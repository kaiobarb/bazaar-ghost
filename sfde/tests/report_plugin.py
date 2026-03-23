"""Pytest plugin that generates a human-readable last_run.txt report.

Collects test outcomes and captured print output, then writes a formatted
report to sfde/tests/last_run.txt at the end of the session.

Metrics are collected via a shared store (report_metrics dict) that tests
write to directly, so they're always available regardless of capture mode.

Frame references like "217917/17258.jpg" are rewritten to relative paths
(fixtures/frames/217917_17258.jpg) so VS Code gutter-preview extensions
can show inline image previews on hover.
"""

import re
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List

import pytest

REPORT_PATH = Path(__file__).resolve().parent / "last_run.txt"

# Pattern: vod_id/frame.jpg where vod_id is digits, frame is digits.jpg
_FRAME_REF_RE = re.compile(r"(\d+)/(\d+\.jpg)")

# Shared metrics store — tests write structured data here
# Key: test nodeid, Value: list of metric strings
report_metrics: Dict[str, List[str]] = {}


def _rewrite_frame_paths(line: str) -> str:
    """Rewrite vod_id/frame.jpg references to relative fixture paths.

    Converts e.g. "217917/17258.jpg" to "fixtures/frames/217917_17258.jpg"
    so gutter-preview extensions resolve the image from the report file location.
    """
    return _FRAME_REF_RE.sub(r"fixtures/frames/\1_\2", line)


def record_metric(request: pytest.FixtureRequest, line: str):
    """Record a metric line for the current test. Call from tests via fixture."""
    nodeid = request.node.nodeid
    report_metrics.setdefault(nodeid, []).append(line)


@pytest.fixture
def metrics(request):
    """Fixture that returns a function to record metric lines for the report."""

    def _record(line: str):
        record_metric(request, line)

    return _record


class ReportCollector:
    def __init__(self):
        self.results: List[Dict[str, Any]] = []
        self.start_time: float = 0

    def add_result(self, nodeid: str, outcome: str, duration: float, captured: str):
        self.results.append(
            {
                "nodeid": nodeid,
                "outcome": outcome,
                "duration": duration,
                "captured": captured.strip() if captured else "",
            }
        )


_collector = ReportCollector()


def pytest_sessionstart(session):
    _collector.start_time = time.time()
    report_metrics.clear()


@pytest.hookimpl(tryfirst=True, hookwrapper=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    report = outcome.get_result()

    if report.when == "call":
        captured = report.capstdout or ""
        _collector.add_result(
            nodeid=report.nodeid,
            outcome=report.outcome,
            duration=report.duration,
            captured=captured,
        )


def pytest_sessionfinish(session, exitstatus):
    elapsed = time.time() - _collector.start_time
    results = _collector.results
    passed = sum(1 for r in results if r["outcome"] == "passed")
    failed = sum(1 for r in results if r["outcome"] == "failed")
    skipped = sum(1 for r in results if r["outcome"] == "skipped")
    total = len(results)
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

    lines = []
    lines.append("=" * 72)
    lines.append("SFDE Test Suite — Last Run Report")
    lines.append("=" * 72)
    lines.append(f"Date:     {now}")
    lines.append(f"Duration: {elapsed:.1f}s")
    lines.append(
        f"Result:   {passed} passed, {failed} failed, {skipped} skipped / {total} total"
    )
    lines.append("")

    # Group results by test file
    by_file: Dict[str, List[Dict]] = {}
    for r in results:
        parts = r["nodeid"].split("::", 1)
        filename = parts[0].replace("tests/", "")
        by_file.setdefault(filename, []).append(r)

    for filename, file_results in by_file.items():
        file_passed = sum(1 for r in file_results if r["outcome"] == "passed")
        file_failed = sum(1 for r in file_results if r["outcome"] == "failed")
        file_total = len(file_results)
        status = "PASS" if file_failed == 0 else "FAIL"

        lines.append("-" * 72)
        lines.append(f"  {filename}  [{status}] {file_passed}/{file_total}")
        lines.append("-" * 72)

        for r in file_results:
            test_name = (
                r["nodeid"].split("::", 1)[1] if "::" in r["nodeid"] else r["nodeid"]
            )
            icon = {"passed": "OK", "failed": "FAIL", "skipped": "SKIP"}.get(
                r["outcome"], "?"
            )
            duration_str = f"{r['duration']:.2f}s"

            lines.append(f"  [{icon:>4}] {test_name}  ({duration_str})")

            # Include metrics recorded via the metrics fixture
            metric_lines = report_metrics.get(r["nodeid"], [])
            for ml in metric_lines:
                lines.append(f"         {_rewrite_frame_paths(ml)}")

            # Also include captured stdout as fallback
            if not metric_lines and r["captured"]:
                for cl in r["captured"].split("\n"):
                    cl = cl.strip()
                    if cl:
                        lines.append(f"         {_rewrite_frame_paths(cl)}")

        lines.append("")

    # Summary section
    lines.append("=" * 72)
    lines.append("Accuracy Summary")
    lines.append("=" * 72)

    # Collect all metric lines tagged with [SUMMARY]
    summary_lines = []
    detail_lines = []
    for nodeid, mlines in report_metrics.items():
        for ml in mlines:
            if ml.startswith("[SUMMARY]"):
                summary_lines.append(ml.replace("[SUMMARY] ", ""))
            elif ml.startswith("[DETAIL]"):
                detail_lines.append(ml.replace("[DETAIL] ", ""))

    if summary_lines:
        for sl in summary_lines:
            lines.append(f"  {sl}")
    else:
        lines.append("  (no summary metrics recorded)")

    if detail_lines:
        lines.append("")
        lines.append("  Breakdown:")
        for dl in detail_lines:
            lines.append(f"    {dl}")

    lines.append("")
    lines.append("=" * 72)

    report_text = "\n".join(lines) + "\n"

    with open(REPORT_PATH, "w") as f:
        f.write(report_text)
