# Executable package consumer

[examples/consumer.ts](examples/consumer.ts) is compiled against the installed
npm tarball, not provider source. It uses memory storage, synthetic events and
a process-local fake fetch; no network endpoint is contacted. It verifies
payload shape, retry/requeue after a 503 response, bounded queue overflow,
missing-endpoint rejection and shutdown cleanup.

Provider command from `sdks/web`:

```sh
npm ci
npm run build
npm run test:distribution
```

The distribution runner creates a private temporary consumer, packs and installs
the real tarball, checks shipped document/schema/version/API entries, typechecks
and runs the installed example, and checks CJS loading. Missing docs, wrong
version, export drift and schema mismatch fail with `WEB_AI_*` errors. Expected
final output is `WEB_DISTRIBUTION_OK`; positive/negative checker tests run via
`npm run test:contract`.

This fake-fetch boundary is not real HTTP/Loki storage evidence, browser
Beacon/lifecycle verification, content redaction or product migration. Browser
tests must use an isolated profile; no real user content or production service
is authorized by this fixture.
