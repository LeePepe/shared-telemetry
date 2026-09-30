#!/usr/bin/env python3
"""Scan the development root to check which projects have LokiKit integrated.

Set DEV_DIR to override the default Development directory under the user's home.

Looks for:
  - lokikit / loki-web imports in source files
  - Loki endpoint references in config files
  - docker-compose references to loki
  - Grafana dashboard JSON files in LokiKit stack
"""

import os
import re
from pathlib import Path

DEV_DIR = Path(os.environ.get("DEV_DIR") or Path.home() / "Development")
LOKIKIT_DASHBOARDS = DEV_DIR / "LokiKit" / "stack" / "grafana" / "dashboards"

# Patterns that indicate LokiKit integration
PATTERNS = {
    "python_import": re.compile(r"(?:from\s+lokikit|import\s+lokikit)", re.IGNORECASE),
    "web_import": re.compile(r"""(?:from\s+['"]@leepepe/loki-web|require\s*\(\s*['"]@leepepe/loki-web)"""),
    "swift_import": re.compile(r"import\s+LokiKit"),
    "loki_endpoint": re.compile(r"loki.*(?:3100|api/v1/push)", re.IGNORECASE),
    "docker_loki": re.compile(r"grafana/loki|loki:\s*\n|image:.*loki", re.IGNORECASE),
}

SEARCH_EXTENSIONS = {
    ".py", ".ts", ".tsx", ".js", ".jsx", ".swift",
    ".yml", ".yaml", ".json", ".toml", ".env", ".cfg",
}

SKIP_DIRS = {"node_modules", ".git", "__pycache__", "dist", "build", ".venv", "venv", ".build", "Pods", "DerivedData", ".tox", "egg-info"}


def scan_project(project_path: Path, max_files: int = 500) -> dict[str, bool]:
    """Return which integration signals are found in a project."""
    signals = {k: False for k in PATTERNS}
    count = 0

    for root, dirs, files in os.walk(project_path):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for fname in files:
            if count >= max_files:
                return signals
            ext = Path(fname).suffix.lower()
            if ext not in SEARCH_EXTENSIONS:
                continue
            count += 1
            fpath = Path(root) / fname
            try:
                text = fpath.read_text(errors="ignore")
            except (OSError, PermissionError):
                continue
            for key, pattern in PATTERNS.items():
                if not signals[key] and pattern.search(text):
                    signals[key] = True
    return signals


def check_dashboard(project_name: str) -> bool:
    """Check if a Grafana dashboard JSON exists for this project."""
    if not LOKIKIT_DASHBOARDS.exists():
        return False
    name_lower = project_name.lower().replace("-", "").replace("_", "")
    for f in LOKIKIT_DASHBOARDS.iterdir():
        if f.suffix == ".json" and name_lower in f.stem.lower().replace("-", "").replace("_", ""):
            return True
    return False


def main():
    projects = sorted(
        p for p in DEV_DIR.iterdir()
        if p.is_dir() and not p.name.startswith(".") and p.name != "LokiKit"
    )

    print(f"{'Project':<30} {'Python':>8} {'Web':>8} {'Swift':>8} {'Endpoint':>10} {'Docker':>8} {'Dashboard':>10} {'Status':>10}")
    print("-" * 102)

    for proj in projects:
        signals = scan_project(proj)
        has_dashboard = check_dashboard(proj.name)

        py = "✅" if signals["python_import"] else "—"
        web = "✅" if signals["web_import"] else "—"
        swift = "✅" if signals["swift_import"] else "—"
        endpoint = "✅" if signals["loki_endpoint"] else "—"
        docker = "✅" if signals["docker_loki"] else "—"
        dash = "✅" if has_dashboard else "—"

        any_sdk = any(signals[k] for k in ("python_import", "web_import", "swift_import"))
        any_signal = any_sdk or signals["loki_endpoint"] or signals["docker_loki"] or has_dashboard

        status = "✅ integrated" if any_sdk else ("⚠️  partial" if any_signal else "❌ none")

        print(f"{proj.name:<30} {py:>8} {web:>8} {swift:>8} {endpoint:>10} {docker:>8} {dash:>10} {status:>10}")


if __name__ == "__main__":
    main()
