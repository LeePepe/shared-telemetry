#!/usr/bin/env python3
"""Strict validator for the deliberately narrow shipped registry schema."""
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[3]


def require(condition, code, detail):
    if not condition:
        raise ValueError(f"{code}: {detail}; see ai/README.md")


def schema_check(value, schema):
    keywords = {"$schema", "title", "type", "additionalProperties", "required", "properties",
                "const", "enum", "minItems", "maxItems", "items"}
    require(not set(schema) - keywords, "SWIFT_AI_SCHEMA", "unsupported schema keyword")
    kind = schema.get("type")
    if kind:
        types = {"object": dict, "array": list, "string": str}
        require(kind in types and type(value) is types[kind], "SWIFT_AI_SCHEMA", "wrong type")
    if "const" in schema:
        require(type(value) is type(schema["const"]) and value == schema["const"], "SWIFT_AI_SCHEMA", "wrong constant")
    if "enum" in schema:
        require(value in schema["enum"], "SWIFT_AI_SCHEMA", "unknown value")
    if kind == "object":
        require(set(schema.get("required", [])) <= set(value), "SWIFT_AI_SCHEMA", "missing field")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            require(not set(value) - set(properties), "SWIFT_AI_SCHEMA", "unknown field")
        for key, item in value.items():
            if key in properties:
                schema_check(item, properties[key])
    if kind == "array":
        require(schema.get("minItems", 0) <= len(value) <= schema.get("maxItems", len(value)), "SWIFT_AI_SCHEMA", "item count")
        for item in value:
            schema_check(item, schema["items"])


def check(root):
    root = root.resolve()
    ai = root / "ai"
    registry = json.loads((ai / "registry.json").read_text())
    schema_check(registry, json.loads((ai / "registry.schema.json").read_text()))

    def resolve(base, target):
        destination = (base / target.split("#", 1)[0]).resolve()
        require(destination.is_relative_to(root), "SWIFT_AI_PATH", target)
        require(destination.is_file(), "SWIFT_AI_DOCUMENT", target)
        return destination

    for name in registry["documents"].values():
        resolve(ai, name)
    resolve(ai, registry["example"])
    for document in ai.glob("*.md"):
        for target in re.findall(r"\[[^\]]*\]\(([^\s)]+)\)", document.read_text()):
            if "://" not in target and not target.startswith("#"):
                resolve(document.parent, target)
    public = {}
    for source in (root / "sdks/swift/Sources/LokiKit").glob("*.swift"):
        for symbol in re.findall(r"public\s+(?:final\s+)?(?:class|enum|struct|protocol)\s+(\w+)", source.read_text()):
            public[symbol] = source.resolve()
    registered = {entry["symbol"]: resolve(ai, entry["source"]) for entry in registry["capabilities"]}
    require(len(registered) == len(registry["capabilities"]) and registered == public,
            "SWIFT_AI_API", "public type/source registry drift")
    for source in (ai / "examples").rglob("*.swift"):
        require("@testable" not in source.read_text(), "SWIFT_AI_EXAMPLE", "test-only import")
    print("SWIFT_AI_OK: schema, documents, public type registry and source-only imports")


if __name__ == "__main__":
    check(ROOT)
