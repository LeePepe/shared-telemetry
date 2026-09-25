---
layer: SwiftSDK
owns: [sdks/swift/**, Package.swift, ai/**]
depends_on: []
gate:
  contract: python3 sdks/swift/scripts/check_contract.py
  contract_tests: python3 sdks/swift/scripts/test_contract.py
  build: swift build
  test: swift test
red_lines:
  - Telemetry and shipped logs carry metrics and allow-listed messages only; user content (text, audio, transcripts, prompts) never enters a payload.
  - LokiLogSink ships only allow-listed messages and finite, allow-listed numeric context; everything else is redacted before it leaves the process.
  - Tests never reach a live network endpoint or the live TelemetryDeck SDK unless explicitly opted in.
  - The root Package.swift and sdks/swift/Package.swift declare the same platforms, products and dependencies.
---

# SwiftSDK

`LokiKit` Swift package, Swift 6.2, iOS 26 / macOS 26. Sources live in
`sdks/swift/Sources/LokiKit`; tests in `sdks/swift/Tests/LokiKitTests`.
The root `Package.swift` points its targets at those directories so consumers
can depend on the repository root. The gate builds and tests through the root
package, which is the one consumers resolve.

Components: `Logger`/`PrintLogger`, `TelemetryService` with
`LokiTelemetryService`, `NoopTelemetryService` and `TelemetryDeckService`,
`TelemetryQueue` (disk-persisted offline queue with retry), `LokiShipper`,
`LokiLogSink` (privacy filter for log shipping) and performance helpers.

External dependency: TelemetryDeck SwiftSDK (`from: 2.0.0`).

Known debt: `VoxPocketTelemetryEventNames.swift` is consumer-specific and should
move to VoxPocket (breaking change; needs a coordinated VoxPocket adopt PR).
