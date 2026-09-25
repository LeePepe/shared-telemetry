#!/usr/bin/env python3
"""Build and consume real wheel/sdist artifacts in a run-owned temporary tree."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
import venv
import zipfile

import jsonschema

SDK = Path(__file__).resolve().parents[1]


def check_contract(package, version):
    ai = package / "ai"
    registry = json.loads((ai / "registry.json").read_text())
    schema = json.loads((ai / "registry.schema.json").read_text())
    try:
        jsonschema.Draft202012Validator.check_schema(schema)
        jsonschema.Draft202012Validator(schema).validate(registry)
    except jsonschema.ValidationError as error:
        raise ValueError(f"PY_AI_SCHEMA: {error.message}") from error
    if registry["version"] != version:
        raise ValueError("PY_AI_VERSION: registry does not match package metadata")

    def resolve(name):
        path = (ai / name.split("#", 1)[0]).resolve()
        if not path.is_relative_to(ai.resolve()):
            raise ValueError(f"PY_AI_PATH: {name}")
        if not path.is_file():
            raise ValueError(f"PY_AI_DOCUMENT: {name}")

    for name in registry["documents"].values():
        resolve(name)
    expected = {("batch-client", "lokikit.LokiClient"), ("logging-handler", "lokikit.LokiHandler")}
    actual = {(entry["id"], entry["symbol"]) for entry in registry["capabilities"]}
    if actual != expected:
        raise ValueError("PY_AI_API: registry capability mismatch")
    for entry in registry["capabilities"]:
        resolve(entry["documentation"])
        resolve(entry["example"])
    for document in ai.glob("*.md"):
        for target in re.findall(r"\[[^\]]*\]\(([^\s)]+)\)", document.read_text()):
            if "://" not in target and not target.startswith("#"):
                resolve(target)


def run(*args, cwd):
    subprocess.run(args, cwd=cwd, check=True)


def check_resource_bytes(actual, expected):
    if not set(expected) <= set(actual):
        raise ValueError("PY_AI_ARTIFACT: distribution omits contract resources")
    if any(actual[name] != content for name, content in expected.items()):
        raise ValueError("PY_AI_ARTIFACT: distributed contract differs from validated source")


def main():
    with tempfile.TemporaryDirectory(prefix="lokikit-python-dist-") as directory:
        root = Path(directory)
        output = root / "dist"
        run(sys.executable, "-m", "build", "--outdir", str(output), str(SDK), cwd=root)
        wheels = list(output.glob("*.whl"))
        sdists = list(output.glob("*.tar.gz"))
        if len(wheels) != 1 or len(sdists) != 1:
            raise ValueError("PY_AI_ARTIFACT: expected one wheel and one sdist")
        expected = {str(path.relative_to(SDK / "src")): path.read_bytes()
                    for path in (SDK / "src/lokikit/ai").rglob("*")
                    if path.is_file() and path.suffix in {".md", ".json", ".py"}}
        with zipfile.ZipFile(wheels[0]) as archive:
            check_resource_bytes({name: archive.read(name) for name in archive.namelist()
                                  if name in expected}, expected)
        with tarfile.open(sdists[0]) as archive:
            members = {"/".join(member.name.split("/")[2:]): member
                       for member in archive.getmembers() if "/src/" in member.name and member.isfile()}
            check_resource_bytes({name: archive.extractfile(member).read()
                                  for name, member in members.items() if name in expected}, expected)
        environment = root / "venv"
        venv.EnvBuilder(with_pip=True).create(environment)
        python = environment / "bin/python"
        run(str(python), "-m", "pip", "install", "--disable-pip-version-check", str(wheels[0]), cwd=root)
        # Isolated interpreter ignores PYTHONPATH and the source checkout.
        code = '''
import importlib.metadata as metadata
from importlib.resources import files
import json
import lokikit
ai = files("lokikit").joinpath("ai")
registry = json.loads(ai.joinpath("registry.json").read_text())
assert registry["version"] == metadata.version("lokikit") == lokikit.__version__
for name in registry["documents"].values():
    assert ai.joinpath(name).is_file(), name
for capability in registry["capabilities"]:
    assert getattr(lokikit, capability["symbol"].split(".")[1])
exec(compile(ai.joinpath("examples/synthetic.py").read_text(), "installed-synthetic.py", "exec"))
print("PYTHON_DISTRIBUTION_OK", metadata.version("lokikit"), metadata.version("aiohttp"))
'''
        run(str(python), "-I", "-c", code, cwd=root)
        check_contract(SDK / "src/lokikit", "0.1.0")
        for artifact in (wheels[0], sdists[0]):
            print(f"PYTHON_ARTIFACT {artifact.name} sha256={hashlib.sha256(artifact.read_bytes()).hexdigest()}")


if __name__ == "__main__":
    main()
