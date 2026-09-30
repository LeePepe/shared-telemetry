#!/usr/bin/env python3
"""project-analyzer runner.

Usage:
    python3 agents/project-analyzer/run.py [--project NAME] [--config PATH]
                                           [--loki-url URL] [--output-dir DIR]
                                           [--dry-run]

Queries Loki for recent `user_action` and `performance` streams for each configured
project, detects anomalies/regressions/error spikes/silent failures, and writes a
per-project markdown report plus a remediation brief when issues are found.
"""
from __future__ import annotations

import argparse
import logging
import os
import sys
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path
from typing import Tuple

# Allow running as a script from any CWD.
_THIS_DIR = Path(__file__).resolve().parent
if str(_THIS_DIR) not in sys.path:
    sys.path.insert(0, str(_THIS_DIR))

from lib.analyzer import (
    ProjectReport,
    build_report,
    summarize_actions,
    summarize_performance,
)
from lib.config import (
    AppConfig,
    ConfigError,
    ProjectConfig,
    filter_projects,
    load_config,
)
from lib.loki_client import LokiClient, LokiError, QueryResult
from lib.report import format_remediation_brief, format_report
from lib.daily import (
    build_daily_summary,
    compute_performance_comparison,
    compute_usage_stats,
    write_daily_json,
)
from lib.dashboard_reporter import DashboardReporter
from lib.loki_stats import query_index_stats, StorageStats


DEFAULT_CONFIG = _THIS_DIR / "config.yaml"
DEFAULT_OUTPUT_DIR = _THIS_DIR / "reports"
EXIT_OK = 0
EXIT_FINDINGS = 2
EXIT_CONFIG_ERR = 3
EXIT_RUNTIME_ERR = 4


log = logging.getLogger("project-analyzer")


def _resolve_config_path(config_path: str | None) -> Path:
    if config_path is not None:
        return Path(config_path)
    env_config = os.environ.get("PROJECT_ANALYZER_CONFIG")
    if env_config:
        return Path(env_config)
    if DEFAULT_CONFIG.exists():
        return DEFAULT_CONFIG
    example = DEFAULT_CONFIG.with_name("config.example.yaml")
    log.warning("Using example config: %s; configure your real project list before use.", example)
    return example


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="project-analyzer",
        description=(
            "Query Loki for recent telemetry per project, detect anomalies, "
            "and write markdown reports + remediation briefs."
        ),
    )
    p.add_argument("--project", help="Run only this project (by name). Default: all.")
    p.add_argument(
        "--config",
        help=(
            "Config path (overrides PROJECT_ANALYZER_CONFIG). Default: "
            "PROJECT_ANALYZER_CONFIG, then config.yaml beside this script, "
            "then config.example.yaml with a warning."
        ),
    )
    p.add_argument(
        "--loki-url",
        default=None,
        help="Override Loki base URL (else LOKI_URL env or config).",
    )
    p.add_argument(
        "--output-dir",
        default=str(DEFAULT_OUTPUT_DIR),
        help=f"Report output directory (default: {DEFAULT_OUTPUT_DIR}).",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Do not query Loki; emit synthetic empty reports (useful for CI smoke).",
    )
    p.add_argument(
        "--daily",
        action="store_true",
        help="Run daily summary mode: emit <date>.daily.json + report to dashboard.",
    )
    p.add_argument(
        "--verbose", "-v", action="store_true", help="Verbose logging."
    )
    return p


def _configure_logging(verbose: bool) -> None:
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )


def _apply_cli_overrides(cfg: AppConfig, loki_url: str | None) -> AppConfig:
    if loki_url:
        if not loki_url.startswith(("http://", "https://")):
            raise ConfigError(f"--loki-url must be http(s), got: {loki_url!r}")
        cfg = replace(cfg, loki=replace(cfg.loki, url=loki_url.rstrip("/")))
    return cfg


def _empty_result(query: str) -> QueryResult:
    return QueryResult(query=query, entries=(), truncated=False)


def _analyze_project(
    client: LokiClient | None,
    cfg: AppConfig,
    project: ProjectConfig,
    *,
    dry_run: bool,
) -> ProjectReport:
    if dry_run or client is None:
        actions_result = _empty_result(project.selector_user_action)
        perf_result = _empty_result(project.selector_performance)
        baseline_actions_result = _empty_result(project.selector_user_action)
        baseline_perf_result = _empty_result(project.selector_performance)
    else:
        actions_result = client.query_range(
            project.selector_user_action,
            cfg.loki.lookback,
            limit=cfg.loki.query_limit,
        )
        perf_result = client.query_range(
            project.selector_performance,
            cfg.loki.lookback,
            limit=cfg.loki.query_limit,
        )
        baseline_actions_result = client.query_range(
            project.selector_user_action,
            cfg.loki.baseline_lookback,
            limit=cfg.loki.query_limit,
        )
        baseline_perf_result = client.query_range(
            project.selector_performance,
            cfg.loki.baseline_lookback,
            limit=cfg.loki.query_limit,
        )

    actions = summarize_actions(actions_result)
    perf = summarize_performance(perf_result)
    baseline_actions_stats = summarize_actions(baseline_actions_result)
    baseline_perf_stats = summarize_performance(baseline_perf_result)
    baseline_p95 = baseline_perf_stats.p95_ms if baseline_perf_stats.samples else None

    return build_report(
        project=project.name,
        repo_path=project.repo_path,
        team_lead=project.team_lead,
        actions=actions,
        perf=perf,
        baseline_actions=baseline_actions_stats.total,
        baseline_p95_ms=baseline_p95,
        thresholds=cfg.thresholds,
    )


def write_report_files(
    report: ProjectReport,
    *,
    output_dir: Path,
    now: datetime | None = None,
) -> Tuple[Path, Path | None]:
    """Write report + (optionally) remediation brief. Returns the paths written."""
    ts = now or datetime.now(timezone.utc)
    date_str = ts.strftime("%Y-%m-%d")
    project_dir = output_dir / report.project
    project_dir.mkdir(parents=True, exist_ok=True)
    report_path = project_dir / f"{date_str}.md"
    report_path.write_text(format_report(report, generated_at=ts), encoding="utf-8")
    brief_path: Path | None = None
    brief = format_remediation_brief(report, generated_at=ts)
    if brief:
        brief_path = project_dir / f"{date_str}.remediation.md"
        brief_path.write_text(brief, encoding="utf-8")
    return report_path, brief_path


def _run_daily(
    client: LokiClient | None,
    cfg: AppConfig,
    projects: list,
    output_dir: Path,
    dry_run: bool,
) -> int:
    """Run the daily summary mode for all projects."""
    from lib.analyzer import PerfStats

    now = datetime.now(timezone.utc)
    date_str = now.strftime("%Y-%m-%d")
    daily_cfg = cfg.raw.get("daily", {})
    lookback = daily_cfg.get("lookback", "24h")
    baseline_lookback = daily_cfg.get("baseline_lookback", "48h")

    # Setup dashboard reporter (best-effort, never fatal)
    reporter = DashboardReporter(
        name=os.environ.get("AGENT_OPS_NAME", "lokikit-project-analyzer"),
        kind="telemetry_analyzer",
        description="LokiKit daily project telemetry analyzer",
    )
    reporter.setup(os.environ.get("AGENT_OPS_BASE_URL"))

    failures: list[str] = []
    for project in projects:
        log.info("[daily] Processing project: %s", project.name)
        app_label = getattr(project, "loki_app_label", project.name.lower())

        # STORAGE
        if dry_run or client is None:
            storage = StorageStats(streams=0, chunks=0, bytes_total=0, entries=0, line_count_proxy=0)
        else:
            storage = query_index_stats(cfg.loki.url, app_label, lookback=lookback, token=cfg.loki.token)

        # USAGE
        if dry_run or client is None:
            usage_result = _empty_result(project.selector_user_action)
        else:
            usage_result = client.query_range(
                project.selector_user_action, lookback, limit=cfg.loki.query_limit
            )
        usage = compute_usage_stats(usage_result)

        # PERFORMANCE current + baseline
        if dry_run or client is None:
            perf_result = _empty_result(project.selector_performance)
            baseline_perf_result = _empty_result(project.selector_performance)
        else:
            perf_result = client.query_range(
                project.selector_performance, lookback, limit=cfg.loki.query_limit
            )
            baseline_perf_result = client.query_range(
                project.selector_performance, baseline_lookback, limit=cfg.loki.query_limit
            )

        current_perf = summarize_performance(perf_result)
        baseline_perf = summarize_performance(baseline_perf_result)
        perf_comparison = compute_performance_comparison(current_perf, baseline_perf)

        summary = build_daily_summary(
            project_name=project.name,
            date=date_str,
            storage=storage,
            usage=usage,
            perf_comparison=perf_comparison,
        )
        json_path = write_daily_json(summary, output_dir)
        log.info("[daily] Wrote %s", json_path)

        # Also write the standard markdown report
        try:
            report = _analyze_project(client, cfg, project, dry_run=dry_run)
            write_report_files(report, output_dir=output_dir, now=now)
        except Exception as e:
            log.warning("[daily] Markdown report failed for %s: %s", project.name, e)

        # Dashboard: heartbeat + record_task (best-effort)
        reporter.heartbeat(status="running", meta={"project": project.name, "mode": "daily"})
        reporter.record_task(
            kind="daily_summary",
            ref=f"{project.name}/{date_str}",
            payload={"project": project.name, "date": date_str, "json_path": str(json_path)},
        )

    if failures:
        log.warning("Projects with errors: %s", ", ".join(failures))
        return EXIT_RUNTIME_ERR
    return EXIT_OK


def run(argv: list[str] | None = None) -> int:
    args = build_arg_parser().parse_args(argv)
    _configure_logging(args.verbose)
    try:
        cfg = load_config(_resolve_config_path(args.config))
        cfg = _apply_cli_overrides(cfg, args.loki_url)
        projects = filter_projects(cfg, args.project)
    except ConfigError as e:
        log.error("Configuration error: %s", e)
        return EXIT_CONFIG_ERR

    output_dir = Path(args.output_dir).expanduser()

    client: LokiClient | None = None
    if not args.dry_run:
        try:
            client = LokiClient(
                base_url=cfg.loki.url,
                timeout=cfg.loki.timeout,
                token=cfg.loki.token,
            )
        except LokiError as e:
            log.error("Failed to build Loki client: %s", e)
            return EXIT_RUNTIME_ERR

    # Daily mode
    if args.daily:
        return _run_daily(client, cfg, projects, output_dir, args.dry_run)

    total_findings = 0
    failures: list[str] = []
    for project in projects:
        log.info("Analyzing project: %s", project.name)
        try:
            report = _analyze_project(client, cfg, project, dry_run=args.dry_run)
        except LokiError as e:
            log.error("[%s] Loki query failed: %s", project.name, e)
            failures.append(project.name)
            continue
        except Exception as e:  # pragma: no cover — defensive
            log.exception("[%s] Unexpected error: %s", project.name, e)
            failures.append(project.name)
            continue
        report_path, brief_path = write_report_files(report, output_dir=output_dir)
        total_findings += len(report.findings)
        log.info(
            "[%s] %d findings → %s%s",
            project.name,
            len(report.findings),
            report_path,
            f" (+ brief {brief_path})" if brief_path else "",
        )

    if failures:
        log.warning("Projects with errors: %s", ", ".join(failures))
        return EXIT_RUNTIME_ERR
    return EXIT_FINDINGS if total_findings else EXIT_OK


if __name__ == "__main__":  # pragma: no cover
    sys.exit(run())
