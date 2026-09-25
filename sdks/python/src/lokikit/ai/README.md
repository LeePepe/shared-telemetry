# LokiKit Python consumer contract

Package: `lokikit`, candidate version **0.1.0**, Python >=3.10.
No registry publication or repository release is claimed by this document.

| Task | Read |
| --- | --- |
| New install, wiring or removal | [INTEGRATION.md](INTEGRATION.md) |
| Public API, errors and privacy limits | [USAGE.md](USAGE.md) |
| Run the installed-package synthetic example | [EXAMPLES.md](EXAMPLES.md) |
| Runtime/dependency support | [COMPATIBILITY.md](COMPATIBILITY.md) |
| Replace an old client or roll back | [MIGRATION.md](MIGRATION.md) |
| Machine discovery | [registry.json](registry.json), [schema](registry.schema.json) |
| User-visible changes | [CHANGELOG.md](CHANGELOG.md) |

These files are wheel/sdist package data. Locate the matching installed copy
with `importlib.resources.files("lokikit").joinpath("ai")`, not a source-checkout
path or floating remote document. Match registry version to
`importlib.metadata.version("lokikit")`; fail on missing/mismatched data.

Examples use synthetic content only. Documentation grants no permission to use
production credentials/endpoints, transmit user content or migrate storage.
