# Changelog

## Unreleased — 0.1.0 candidate

- Include the versioned AI contract and synthetic public-API example in both
  wheel and sdist; no runtime/API/platform change.
- Existing baseline: local-discard accounting via `dropped_entries` and an
  explicit aiohttp request timeout, without retry/requeue or automatic redaction.

No PyPI publication or repository tag is implied. Release blockers and unmeasured
requirements are listed in [COMPATIBILITY.md](COMPATIBILITY.md).
