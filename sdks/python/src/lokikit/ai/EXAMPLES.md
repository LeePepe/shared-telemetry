# Installed-package example

[examples/synthetic.py](examples/synthetic.py) is executable, uses only public
`lokikit` imports and standard-library facilities, and runs a private HTTP
receiver on an ephemeral loopback port. It posts one synthetic event with a
test-only Bearer token, checks actual received bytes, then verifies HTTP 401
rejection increments local loss accounting. It also tests a logging handler
with an allow-listed synthetic message. All resources belong to this run.

Run against the installed wheel from outside the source tree:

```sh
python -c 'from importlib.resources import files; exec(files("lokikit").joinpath("ai/examples/synthetic.py").read_text())'
```

Expected: `PYTHON_CONSUMER_OK`, exit 0. Missing package resources, payload drift
or incorrect loss accounting fails the process. This is real HTTP integration
against a test receiver, not Loki storage, production authentication, retry,
redaction or all-interface acceptance. The example never reads environment
credentials and never uses the default client endpoint.

Provider distribution validation is `python sdks/python/scripts/check_distribution.py`.
It builds wheel/sdist, verifies included docs, installs the actual wheel in a
temporary venv, and executes the installed example. No editable/source-path
install is accepted as distribution evidence.
