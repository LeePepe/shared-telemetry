#!/usr/bin/env python3
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from check_contract import ROOT, check


class ContractTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="loki-swift-contract-")
        self.root = Path(self.scratch.name)
        for name in ("ai", "sdks/swift/Sources", "sdks/swift/README.md", "sdks/python/README.md", "sdks/web/README.md"):
            source = ROOT / name
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            if source.is_dir():
                shutil.copytree(source, target)
            else:
                shutil.copy2(source, target)

    def tearDown(self):
        self.scratch.cleanup()

    def test_valid(self):
        check(self.root)

    def test_missing_document(self):
        (self.root / "ai/INTEGRATION.md").unlink()
        with self.assertRaisesRegex(ValueError, "SWIFT_AI_DOCUMENT"):
            check(self.root)

    def test_wrong_version(self):
        file = self.root / "ai/registry.json"
        registry = json.loads(file.read_text())
        registry["version"] = "0.2.0"
        file.write_text(json.dumps(registry))
        with self.assertRaisesRegex(ValueError, "SWIFT_AI_SCHEMA"):
            check(self.root)

    def test_api_drift(self):
        file = self.root / "sdks/swift/Sources/LokiKit/TelemetryService.swift"
        file.write_text(file.read_text().replace("public struct TelemetryEvent", "struct TelemetryEvent"))
        with self.assertRaisesRegex(ValueError, "SWIFT_AI_API"):
            check(self.root)

    def test_path_escape(self):
        (self.root / "ai/README.md").write_text("[bad](../../outside.md)")
        with self.assertRaisesRegex(ValueError, "SWIFT_AI_PATH"):
            check(self.root)

    def test_testable_consumer_rejected(self):
        (self.root / "ai/examples/swift/Tests/ConsumerTests/ConsumerTests.swift").write_text("@testable import LokiKit")
        with self.assertRaisesRegex(ValueError, "SWIFT_AI_EXAMPLE"):
            check(self.root)


if __name__ == "__main__":
    unittest.main()
