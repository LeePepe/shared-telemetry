# Changelog

## 0.1.0 — first release (Git tag v0.1.0)

- Include the versioned AI contract and synthetic public-API example in both
  wheel and sdist; no runtime/API/platform change.
- Existing baseline: local-discard accounting via `dropped_entries` and an
  explicit aiohttp request timeout, without retry/requeue or automatic redaction.

First release, distributed as wheel/sdist built from Git tag `v0.1.0`; no PyPI
publication. Licensed under MIT (repository root `LICENSE`). Open
target gaps remain in
[COMPATIBILITY.md](COMPATIBILITY.md).
