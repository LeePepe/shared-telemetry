# AGENTS.md — shared-telemetry

Last-Reviewed: 2026-09-24

shared-telemetry (package and SDK name `LokiKit`) is the shared local telemetry
backend (Loki + Grafana) plus the Swift, Web and Python SDKs that push logs and
events to it, and a per-project Loki analyzer. Every agent that edits it follows
the protocol below. Tool-specific files (CLAUDE.md etc.) only point here.

## Read first

1. `docs/architecture/tech-context.md` — layer table: layer → paths → depends_on
   (no constitution in this repository)
2. The leaf `tech-context.md` of every layer you touch
   (`python3 .shared-ci/scripts/context/_context.py contexts <path>` after one `scripts/verify`)
3. Guides: `README.md`, `sdks/README.md`, `docs/onboarding-checklist.md`

Layers (independent; no SDK depends on another):

```
SwiftSDK         sdks/swift/**, Package.swift   swift build / swift test (root package)
WebSDK           sdks/web/**                    npm ci, typecheck, vitest run, tsup build
PythonSDK        sdks/python/**                 pytest
ProjectAnalyzer  agents/project-analyzer/**     pytest
Stack            stack/**                       Docker Compose + Grafana; no automated gate
```

A change that spans 2+ layers is too big: split it by layer, unless one wire
contract change must land in every SDK at once (say so in Intent).

## Protocol

Follow `LeePepe/shared-ci@761fe6b0b3ca5e2c57d244182d495ab8041851fa/ai/agent-protocol.md`
(https://github.com/LeePepe/shared-ci/blob/761fe6b0b3ca5e2c57d244182d495ab8041851fa/ai/agent-protocol.md).
It must be the same SHA as the `uses:` pins in `.github/workflows/`.

## Verify

```sh
git config core.hooksPath .githooks   # once per clone
scripts/ci/setup.sh                   # once per clone: .venv with Python SDK + analyzer deps
scripts/verify                        # policy + changed layers vs origin/main (what pre-push runs)
scripts/verify --all                  # policy + every layer gate
scripts/verify --policy               # contract audit + workflow-lint only
scripts/verify --layer WebSDK         # one layer (CI lanes call it this way)
```

- Tooling: Swift 6.2 with the macOS 26 SDK, Node 18+ with npm, Python 3.10+.
- `npm test` in `sdks/web` starts vitest in watch mode; the gate runs `vitest --run`.
- Never `--no-verify`, never weaken or skip tests, never edit policy/gates to pass.

## Required checks

Merging to `main` requires (must match the ruleset):

- `quality / aggregate`

The live ruleset `main protection` currently enforces PR-only merges, no
deletion and no force-push; adding `quality / aggregate` as a required status
check is an Owner ruleset change. There is no AI review check:
`codex-review-target / codex-review` needs a self-hosted runner, which this
repository does not have (see Red lines).

## Red lines

- Privacy: telemetry and shipped logs carry metrics, labels and allow-listed
  messages only. User content (typed or refined text, audio, transcripts,
  prompts) never enters a payload. The Swift `LokiLogSink` redacts anything not
  allow-listed; do not widen its allow-lists without an explicit request.
- Tests never reach live endpoints (Loki, Grafana, TelemetryDeck) unless they
  are explicitly opt-in live tests.
- Secrets: no tokens or passwords in code, tests, fixtures or config. Bearer
  tokens come from the caller or `LOKI_TOKEN`.
- Non-public project configuration (hosts, endpoints, credentials) lives in a
  gitignored local file with a committed `.example` template
  (`stack/.env` ← `stack/.env.example`).
- Grafana assets (`stack/grafana/**`) and `agents/project-analyzer/**` change
  only when a task names them.
- Public API of the SDKs is consumed by other repositories (VoxPocket, Financial
  frontend): a breaking change needs a coordinated consumer adopt PR.
- No personal account names, credential-profile paths or local home paths in the repo.

Approved exceptions:

- No `codex-review-target / codex-review` check (no self-hosted runner); the
  shared-ci ruleset template's review requirement is not applied here. Owner-
  approved for the S7 rollout.
- The Stack layer has no automated gate (needs Docker); verify manually.

## Dependencies

- `shared-ci` `761fe6b0b3ca5e2c57d244182d495ab8041851fa` — https://github.com/LeePepe/shared-ci/blob/761fe6b0b3ca5e2c57d244182d495ab8041851fa/ai/
- No other shared library. External: TelemetryDeck SwiftSDK (SwiftSDK), aiohttp
  (PythonSDK), requests + PyYAML (ProjectAnalyzer).

## Delivery

- One task → one branch + worktree → one PR using `.github/pull_request_template.md`.
- Done = required checks green on the PR head SHA; a new push invalidates old evidence.
- CODEOWNERS paths (`.github/**`, hooks, `scripts/verify`, `scripts/ci/`,
  tech-context, AGENTS/CLAUDE, manifests and lockfiles) need Owner approval;
  until enforced, add the `owner-review` label.
- Report the commit, `scripts/verify` result and PR URL.
