---
layer: WebSDK
owns: [sdks/web/**]
depends_on: []
gate:
  install: npm --prefix sdks/web ci --no-audit --no-fund
  typecheck: npm --prefix sdks/web run typecheck
  test: npm --prefix sdks/web run test -- --run
  build: npm --prefix sdks/web run build
red_lines:
  - No runtime dependencies; the published bundle stays dependency-free.
  - Payloads carry only caller-supplied labels and fields; the SDK never collects page content or user input on its own.
  - package-lock.json is committed and CI installs with npm ci.
---

# WebSDK

`@leepepe/loki-web`, TypeScript, ESM + CJS via tsup, tests with vitest
(happy-dom). Mirrors the Swift `LokiKit` API: `LokiClient` batches entries and
flushes on interval, size and page hide (beacon when no bearer token is set).

`npm test` starts vitest in watch mode; gates and CI always pass `--run`.
