"""Smoke tests: config loading + report formatting with a mocked Loki response.

Runnable both via pytest and directly:
    python3 -m pytest agents/project-analyzer/tests/ -q
    python3 agents/project-analyzer/tests/test_smoke.py
"""
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from lib.analyzer import summarize_actions, summarize_performance  # noqa: E402
from lib.config import load_config  # noqa: E402
from lib.loki_client import LokiClient, LogEntry, QueryResult  # noqa: E402
from lib.report import format_remediation_brief, format_report  # noqa: E402
from run import (  # noqa: E402
    _analyze_project, _resolve_config_path, build_arg_parser, write_report_files,
)


CONFIG_PATH = ROOT / "config.example.yaml"


def _fake_loki_payload(lines):
    values = [[str(ts), line] for ts, line in lines]
    return {
        "status": "success",
        "data": {
            "resultType": "streams",
            "result": [
                {
                    "stream": {"app": "Financial", "level": "info"},
                    "values": values,
                }
            ],
        },
    }


class ConfigTests(unittest.TestCase):
    def test_loads_all_known_projects(self):
        cfg = load_config(CONFIG_PATH)
        names = [p.name for p in cfg.projects]
        self.assertEqual(
            set(names),
            {"example-web", "example-ios"},
        )
        self.assertTrue(cfg.loki.url.startswith("http"))
        self.assertGreater(cfg.loki.query_limit, 0)

    def test_env_overrides_loki_url(self):
        with patch.dict("os.environ", {"LOKI_URL": "http://loki.example:3100"}):
            cfg = load_config(CONFIG_PATH)
        self.assertEqual(cfg.loki.url, "http://loki.example:3100")

    def test_config_path_precedence(self):
        with TemporaryDirectory() as tmp:
            local = Path(tmp) / "config.yaml"
            local.touch()
            env_config = Path(tmp) / "custom.yaml"
            with patch("run.DEFAULT_CONFIG", local), patch.dict(
                "os.environ", {"PROJECT_ANALYZER_CONFIG": str(env_config)}, clear=True
            ):
                parser = build_arg_parser()
                self.assertEqual(_resolve_config_path(parser.parse_args([]).config), env_config)
                args = parser.parse_args(["--config", str(CONFIG_PATH)])
                self.assertEqual(_resolve_config_path(args.config), CONFIG_PATH)
            with patch("run.DEFAULT_CONFIG", local), patch.dict("os.environ", {}, clear=True):
                self.assertEqual(_resolve_config_path(None), local)

    def test_config_path_falls_back_to_example(self):
        with TemporaryDirectory() as tmp:
            local = Path(tmp) / "config.yaml"
            example = Path(tmp) / "config.example.yaml"
            example.touch()
            with patch("run.DEFAULT_CONFIG", local), patch.dict("os.environ", {}, clear=True):
                with self.assertLogs("project-analyzer", level="WARNING") as captured:
                    self.assertEqual(_resolve_config_path(None), example)
                self.assertIn("example config", captured.output[0])


class AnalyzerTests(unittest.TestCase):
    def test_summarize_actions_error_spike(self):
        entries = tuple(
            LogEntry(
                ts_ns=i,
                line=json.dumps({"level": "error", "error_type": "HTTP500"}),
                labels={"app": "Financial"},
            )
            for i in range(10)
        ) + tuple(
            LogEntry(
                ts_ns=100 + i,
                line=json.dumps({"level": "info", "action": "click"}),
                labels={"app": "Financial"},
            )
            for i in range(5)
        )
        result = QueryResult(query="q", entries=entries, truncated=False)
        stats = summarize_actions(result)
        self.assertEqual(stats.total, 15)
        self.assertEqual(stats.errors, 10)
        self.assertAlmostEqual(stats.error_rate, 10 / 15, places=4)
        self.assertEqual(stats.top_errors[0][0], "HTTP500")

    def test_summarize_performance_percentiles(self):
        entries = tuple(
            LogEntry(
                ts_ns=i,
                line=json.dumps({"action": "load", "duration_ms": float(i)}),
                labels={},
            )
            for i in range(1, 101)
        )
        result = QueryResult(query="q", entries=entries, truncated=False)
        perf = summarize_performance(result)
        self.assertEqual(perf.samples, 100)
        self.assertGreaterEqual(perf.p95_ms, 90)
        self.assertLessEqual(perf.p95_ms, 100)
        self.assertEqual(perf.slowest_ops[0][0], "load")


class LokiClientParseTests(unittest.TestCase):
    def test_query_range_parses_payload(self):
        client = LokiClient(base_url="http://localhost:3100", timeout=5)

        class FakeResp:
            status_code = 200

            def json(self_inner):  # noqa: N802
                return _fake_loki_payload(
                    [
                        (1_700_000_000_000_000_000, '{"action":"click","duration_ms":10}'),
                        (1_700_000_001_000_000_000, '{"level":"error","error_type":"X"}'),
                    ]
                )

        with patch.object(client._session, "get", return_value=FakeResp()):
            result = client.query_range('{app="Financial"}', "5m", limit=10)
        self.assertEqual(len(result.entries), 2)
        self.assertFalse(result.truncated)


class EndToEndReportTests(unittest.TestCase):
    def test_dry_run_produces_report(self):
        cfg = load_config(CONFIG_PATH)
        project = cfg.projects[0]
        report = _analyze_project(None, cfg, project, dry_run=True)
        md = format_report(report)
        self.assertIn(project.name, md)
        self.assertIn("Findings", md)
        # Dry run with zero data → triggers the low-severity "no telemetry" anomaly.
        self.assertTrue(report.findings)
        brief = format_remediation_brief(report)
        self.assertIn(project.repo_path, brief)

    def test_write_report_files(self):
        import tempfile

        cfg = load_config(CONFIG_PATH)
        project = cfg.projects[1]
        report = _analyze_project(None, cfg, project, dry_run=True)
        with tempfile.TemporaryDirectory() as tmp:
            rp, bp = write_report_files(report, output_dir=Path(tmp))
            self.assertTrue(rp.exists())
            self.assertIn(project.name, rp.read_text())
            if bp is not None:
                self.assertTrue(bp.exists())

    def test_arg_parser_help(self):
        # Must be constructible — underpins the --help smoke check.
        parser = build_arg_parser()
        self.assertIn("project-analyzer", parser.prog)


class StorageQueryParsingTests(unittest.TestCase):
    """Smoke tests for Loki /index/stats response parsing."""

    def test_parse_index_stats_response(self):
        from lib.loki_stats import parse_index_stats_response
        mock_response = {
            "streams": 42,
            "chunks": 1234,
            "bytes": 5678900,
            "entries": 99999,
        }
        stats = parse_index_stats_response(mock_response)
        self.assertEqual(stats.streams, 42)
        self.assertEqual(stats.chunks, 1234)
        self.assertEqual(stats.bytes_total, 5678900)
        self.assertEqual(stats.entries, 99999)
        self.assertEqual(stats.line_count_proxy, 99999)

    def test_parse_index_stats_empty(self):
        from lib.loki_stats import parse_index_stats_response
        stats = parse_index_stats_response({})
        self.assertEqual(stats.streams, 0)
        self.assertEqual(stats.bytes_total, 0)

    def test_parse_duration_seconds(self):
        from lib.loki_stats import _parse_duration_seconds
        self.assertEqual(_parse_duration_seconds("24h"), 86400)
        self.assertEqual(_parse_duration_seconds("1d"), 86400)
        self.assertEqual(_parse_duration_seconds("30m"), 1800)


class DailyJsonSchemaTests(unittest.TestCase):
    """Smoke tests for daily JSON output schema."""

    def test_daily_summary_json_schema(self):
        from lib.daily import (
            DailySummary, UsageStats, PerformanceComparison,
            daily_summary_to_json,
        )
        from lib.loki_stats import StorageStats

        summary = DailySummary(
            project="test-project",
            date="2025-01-15",
            generated_at="2025-01-15T08:00:00+00:00",
            storage=StorageStats(streams=10, chunks=100, bytes_total=5000, entries=200, line_count_proxy=200),
            usage=UsageStats(
                total_actions=50, distinct_action_count=5, unique_sessions=10,
                top_actions=(("click", 20), ("load", 15)),
                error_count=2, error_rate=0.04,
            ),
            performance=PerformanceComparison(
                current_p50_ms=10.0, current_p95_ms=50.0, current_p99_ms=100.0,
                baseline_p50_ms=9.0, baseline_p95_ms=45.0, baseline_p99_ms=90.0,
                samples_current=100, samples_baseline=80, p95_change_pct=11.11,
            ),
        )
        raw = daily_summary_to_json(summary)
        obj = json.loads(raw)
        self.assertEqual(obj["project"], "test-project")
        self.assertEqual(obj["date"], "2025-01-15")
        self.assertIn("storage", obj)
        self.assertIn("usage", obj)
        self.assertIn("performance", obj)
        self.assertEqual(obj["storage"]["streams"], 10)
        self.assertEqual(obj["usage"]["total_actions"], 50)
        self.assertAlmostEqual(obj["performance"]["p95_change_pct"], 11.11)

    def test_daily_dry_run(self):
        """--daily --dry-run should succeed (exit 0)."""
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            from run import run as run_main
            rc = run_main([
                "--config", str(CONFIG_PATH), "--daily", "--dry-run", "--output-dir", tmp,
            ])
            self.assertEqual(rc, 0)
            # Check that at least one .daily.json was created
            json_files = list(Path(tmp).rglob("*.daily.json"))
            self.assertTrue(len(json_files) > 0, "Expected at least one .daily.json file")
            # Validate it's valid JSON with expected keys
            content = json.loads(json_files[0].read_text())
            for key in ("project", "date", "storage", "usage", "performance"):
                self.assertIn(key, content)


class DashboardReporterNoOpTests(unittest.TestCase):
    """Reporter should be no-op when dashboard is unreachable."""

    def test_reporter_noop_when_unreachable(self):
        from lib.dashboard_reporter import DashboardReporter
        reporter = DashboardReporter(
            name="test-agent", kind="test", description="unit test"
        )
        # Setup against a non-existent URL — should not raise
        reporter.setup("http://127.0.0.1:1")
        self.assertFalse(reporter.enabled)
        # These should all be silent no-ops
        reporter.heartbeat(status="running")
        reporter.record_task(kind="test", ref="ref/1")

    def test_reporter_heartbeat_noop_without_setup(self):
        from lib.dashboard_reporter import DashboardReporter
        reporter = DashboardReporter(name="x", kind="x")
        # No setup called — should not raise
        reporter.heartbeat()
        reporter.record_task(kind="test")


if __name__ == "__main__":
    unittest.main(verbosity=2)
