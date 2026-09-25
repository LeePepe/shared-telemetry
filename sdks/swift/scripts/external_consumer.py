#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def run(*args, cwd):
    subprocess.run(args, cwd=cwd, check=True)


def main():
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--revision")
    group.add_argument("--version")
    args = parser.parse_args()
    requested = args.revision or args.version
    if not re.fullmatch(r"[0-9a-f]{40}" if args.revision else r"[0-9]+\.[0-9]+\.[0-9]+", requested):
        parser.error("expected full immutable SHA or exact semver")
    fixture = Path(__file__).resolve().parents[3] / "ai/examples/swift"
    with tempfile.TemporaryDirectory(prefix="lokikit-swift-consumer-") as directory:
        root = Path(directory)
        consumer = root / "consumer"
        shutil.copytree(fixture, consumer)
        manifest = consumer / "Package.swift"
        requirement = f'revision: "{requested}"' if args.revision else f'exact: "{requested}"'
        content, count = re.subn(r'revision: "[0-9a-f]{40}"', requirement, manifest.read_text())
        if count != 1:
            raise RuntimeError("expected exactly one immutable fixture pin")
        manifest.write_text(content)
        run("swift", "package", "resolve", cwd=consumer)
        pins = {entry["identity"]: entry["state"] for entry in json.loads((consumer / "Package.resolved").read_text())["pins"]}
        field = "revision" if args.revision else "version"
        if pins["shared-telemetry"][field] != requested:
            raise RuntimeError("resolved SDK does not match requested candidate")
        checkout = consumer / ".build/checkouts/shared-telemetry"
        registry = json.loads((checkout / "ai/registry.json").read_text())
        if registry["version"] != "0.1.0" or registry["product"] != "LokiKit":
            raise RuntimeError("resolved SDK documentation mismatch")
        if args.version and registry["releaseStatus"] != "released":
            raise RuntimeError("release tag ships an unreleased contract")
        run("python3", str(checkout / "sdks/swift/scripts/check_contract.py"), cwd=checkout)
        run("swift", "build", cwd=consumer)
        run("swift", "test", cwd=consumer)
        run("xcodebuild", "-quiet", "-scheme", "LokiKitConsumer", "-destination", "generic/platform=iOS Simulator",
            "-derivedDataPath", str(root / "DerivedData"), "CODE_SIGNING_ALLOWED=NO", "build-for-testing", cwd=consumer)
        print(f"SWIFT_CONSUMER_OK {field}={requested} pins={json.dumps(pins, sort_keys=True)}")


if __name__ == "__main__":
    main()
