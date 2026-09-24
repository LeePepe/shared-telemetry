---
name: loki-telemetry-integration
description: Integrate a repo with the shared local Loki + Grafana telemetry stack — start the stack, wire up the Swift or Web SDK, add a Grafana dashboard, and follow label conventions.
metadata:
  author: LeePepe
  version: "0.1.0"
---

# Loki Telemetry Integration

Wire a new app (Swift, React, Node, or plain browser) into the shared
local Loki + Grafana stack, or switch the same code to Grafana Cloud
without changes.

## 1. When to use

Trigger this skill when:

- A user wants logs, metrics, or events from a new app surfaced in
  Grafana.
- A user mentions Loki, Grafana, or "the telemetry stack".
- A user is adding telemetry to a Swift (iOS/macOS) project or a
  React / Next.js / Node 18+ project.
- A user asks to add a dashboard for their project.

## 2. Prerequisites

- Docker Desktop running.
- The monorepo checked out locally. Default path:
  `~/Development/LokiKit`. Agents MAY override with
  `LOKI_STACK_DIR`.
- Ports `3100` (Loki) and `3010` (Grafana) available, or customize
  via `stack/.env`.

## 3. Start the stack

    cd "${LOKI_STACK_DIR:-$HOME/Development/LokiKit}/stack"
    cp -n .env.example .env            # first run only
    docker compose up -d

Endpoints:

- Grafana UI:     http://localhost:3010   (admin / telemetry)
- Loki push URL:  http://localhost:3100/loki/api/v1/push

Verify:

    curl -s http://localhost:3100/ready
    # -> "ready"

## 4. Integrate Swift (iOS / macOS)

Add LokiKit as a local SPM dependency in `Package.swift`:

    dependencies: [
        .package(path: "../LokiKit/sdks/swift")
    ],
    targets: [
        .target(name: "MyApp", dependencies: [
            .product(name: "LokiKit", package: "swift")
        ])
    ]

Usage:

    import LokiKit

    let telemetry = LokiTelemetryService(
        endpoint: URL(string: ProcessInfo.processInfo.environment["LOKI_ENDPOINT"]
                    ?? "http://localhost:3100/loki/api/v1/push")!,
        appLabels: ["app": "MyApp", "env": "dev"],
        authToken: ProcessInfo.processInfo.environment["LOKI_TOKEN"] // nil locally
    )

    telemetry.track(name: "recording.started", properties: ["provider": "whisper"])
    await telemetry.flush()   // call on background / quit

Env vars the client reads:

- `LOKI_ENDPOINT` — push URL
- `LOKI_TOKEN`    — Bearer token (unset for local dev)

## 5. Integrate Web (browser or Node 18+)

Package name: `@leepepe/loki-web` (not yet on npm).

Install from the monorepo path:

    npm install ../LokiKit/sdks/web
    # or use npm link:
    #   cd ../LokiKit/sdks/web && npm link
    #   cd your-app && npm link @leepepe/loki-web

Usage:

    import { LokiTelemetry } from '@leepepe/loki-web';

    const telemetry = new LokiTelemetry({
        endpoint: process.env.LOKI_ENDPOINT
                  ?? 'http://localhost:3100/loki/api/v1/push',
        token:    process.env.LOKI_TOKEN,          // omit for local
        labels:   { app: 'MyApp', env: 'dev' },
        maxQueueSize: 1000,
    });

    telemetry.track('page.view', { path: location.pathname });
    telemetry.log('info', 'checkout started', { cartId });
    await telemetry.flush();
    await telemetry.shutdown();    // on teardown

Framework notes:

- Vite / plain browser: ESM import works directly.
- Next.js server routes: runs in Node — import at module top.
- Next.js client components: add `'use client'` and construct inside
  a `useEffect` (or a provider) so it only runs in the browser.
- The SDK auto-flushes on `pagehide`, so normal tab close is covered.

## 6. Label conventions

Keep dashboards consistent across projects.

Required labels (must be passed at SDK init):

- `app` — PascalCase project name, e.g. `Financial`, `VoxPocket`.
- `env` — one of `dev`, `staging`, `prod`.

Optional labels:

- `version`   — semver string
- `component` — subsystem, e.g. `api`, `worker`, `ui`
- `user_hash` — hashed user id (NEVER raw PII)

Reserved — do NOT pass in `labels`, set via the SDK call:

- `event`  — set by `track(name, ...)` / the event name
- `level`  — set by `log(level, ...)`

Example init labels:

    { app: "Financial", env: "dev" }

## 7. Add a Grafana dashboard for your app

1. Build the dashboard in Grafana UI (http://localhost:3010).
2. Share → Export → "Save to file" (raw JSON, not "Export for sharing
   externally").
3. Save to:

       stack/grafana/dashboards/<your-app>.json     # kebab-case

4. Reload:

       cd "${LOKI_STACK_DIR:-$HOME/Development/LokiKit}/stack"
       docker compose restart grafana
       # (Grafana also rescans the folder every 30s.)

5. Register your app in the monorepo README under
   "Projects Using This Stack" with its label and dashboard path.

Reference query pattern (see `stack/grafana/dashboards/financial.json`):

    sum by (method) (rate({app="Financial", event="api.request"} | logfmt [$__auto]))

## 8. Local ↔ Grafana Cloud switch

Same code, different env vars.

Local (default):

    LOKI_ENDPOINT=http://localhost:3100/loki/api/v1/push
    # LOKI_TOKEN unset

Grafana Cloud:

    LOKI_ENDPOINT=https://logs-prod-xxx.grafana.net/loki/api/v1/push
    LOKI_TOKEN=<instance-id>:<api-key>     # Bearer token

Swift: pass `authToken:` to `LokiTelemetryService(...)`.
Web:   pass `token:` to `new LokiTelemetry({...})`.

## 9. Troubleshooting

- `connection refused` on push
  → Stack not up. `cd stack && docker compose ps`; `docker compose up -d`.

- No logs show in Grafana
  → In Explore, run `{app="YourApp"}`. If empty, the SDK never
    connected or labels don't match what you queried.

- Error mentioning `allow_structured_metadata`
  → Already disabled in `stack/loki-config.yaml`; pull latest and
    restart the stack.

- Queue growing unbounded / memory climbing
  → Endpoint unreachable or auth wrong. Check `LOKI_ENDPOINT`,
    `LOKI_TOKEN`, and `maxQueueSize`. Confirm with the readiness
    curl in §3.

- 401/403 against Grafana Cloud
  → Token format must be `<instanceID>:<apiKey>`; verify the key has
    the `logs:write` scope.

## 10. Verification checklist

Before declaring integration done, run all three:

1. Stack is ready:

       curl -s http://localhost:3100/ready
       # -> ready

2. App actually pushes — emit one test event, then:

       curl -G 'http://localhost:3100/loki/api/v1/query' \
         --data-urlencode 'query={app="<YourApp>"}' | head
       # non-empty "values" array

3. If a dashboard was requested: file exists at
   `stack/grafana/dashboards/<your-app>.json` and is visible in the
   Grafana UI after `docker compose restart grafana`.
