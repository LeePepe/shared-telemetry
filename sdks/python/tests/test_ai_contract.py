"""Contract negatives complement the installed-wheel integration fixture."""
import importlib.util
import json
from pathlib import Path
import shutil

import pytest

SDK = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("distribution", SDK / "scripts/check_distribution.py")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


@pytest.fixture
def package(tmp_path):
    target = tmp_path / "lokikit"
    shutil.copytree(SDK / "src/lokikit/ai", target / "ai")
    return target


def test_valid_contract(package):
    CHECK.check_contract(package, "0.1.0")


def test_package_version_mismatch(package):
    with pytest.raises(ValueError, match="PY_AI_VERSION"):
        CHECK.check_contract(package, "0.2.0")


def test_missing_installed_document(package):
    (package / "ai/INTEGRATION.md").unlink()
    with pytest.raises(ValueError, match="PY_AI_DOCUMENT"):
        CHECK.check_contract(package, "0.1.0")


def test_invalid_registry_schema(package):
    path = package / "ai/registry.json"
    data = json.loads(path.read_text())
    data["schemaVersion"] = 999
    path.write_text(json.dumps(data))
    with pytest.raises(ValueError, match="PY_AI_SCHEMA"):
        CHECK.check_contract(package, "0.1.0")


def test_duplicate_capability_not_complete(package):
    path = package / "ai/registry.json"
    data = json.loads(path.read_text())
    data["capabilities"][1] = data["capabilities"][0]
    path.write_text(json.dumps(data))
    with pytest.raises(ValueError, match="PY_AI_API"):
        CHECK.check_contract(package, "0.1.0")


def test_document_cannot_escape_installed_package(package):
    (package / "ai/README.md").write_text("[bad](../../outside.md)")
    with pytest.raises(ValueError, match="PY_AI_PATH"):
        CHECK.check_contract(package, "0.1.0")


def test_missing_distribution_resource_fails():
    with pytest.raises(ValueError, match="PY_AI_ARTIFACT"):
        CHECK.check_resource_bytes({}, {"lokikit/ai/README.md": b"contract"})


def test_distribution_cannot_rewrite_validated_contract():
    with pytest.raises(ValueError, match="PY_AI_ARTIFACT"):
        CHECK.check_resource_bytes({"lokikit/ai/README.md": b"changed"},
                                   {"lokikit/ai/README.md": b"contract"})
