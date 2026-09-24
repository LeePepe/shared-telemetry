---
layer: PythonSDK
owns: [sdks/python/**]
depends_on: []
gate:
  test: python3 -m pytest -q sdks/python/tests
red_lines:
  - Never raise into the host application from the logging path; failures are counted, not thrown.
  - No credentials in code, tests or fixtures; the bearer token comes from the caller or LOKI_TOKEN.
---

# PythonSDK

`lokikit` (Python >= 3.10): `LokiClient` (batching, background flush, sync and
aiohttp paths) and `LokiHandler` (`logging.Handler`). Tests in
`sdks/python/tests` run with pytest and pytest-asyncio.

The gate expects the package installed with its dev extra:
`python3 -m pip install -e 'sdks/python[dev]'`.
