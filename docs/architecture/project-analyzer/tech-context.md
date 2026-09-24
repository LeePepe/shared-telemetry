---
layer: ProjectAnalyzer
owns: [agents/project-analyzer/**]
depends_on: []
gate:
  test: python3 -m pytest -q agents/project-analyzer/tests
red_lines:
  - Read-only against Loki; never writes to consumer repositories.
  - No bearer tokens in config.yaml; use LOKI_TOKEN.
---

# ProjectAnalyzer

Per-project telemetry review agent in `agents/project-analyzer` (see its
README). Queries Loki for `user_action` and `performance` streams, detects error
spikes, latency regressions, silent failures and missing telemetry, and writes
markdown reports (`--daily` adds storage, usage and performance metrics).

The gate expects `python3 -m pip install -r agents/project-analyzer/requirements.txt pytest`.
This leaf lives under `docs/architecture/` so the analyzer directory itself is unchanged.
