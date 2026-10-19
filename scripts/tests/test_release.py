#!/usr/bin/env python3
"""Fixture-only tests for the repository-owned Swift release adapters."""

from __future__ import annotations

import contextlib
import io
import os
import pathlib
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from scripts.release import publish as publish_adapter
from scripts.release.shared import (
    CODEX_CHECK,
    QUALITY_CHECK,
    ReleaseError,
    assess_release,
)


BASELINE = "a" * 40
CANDIDATE = "b" * 40
PR_HEAD = "c" * 40
OTHER_COMMIT = "d" * 40
OTHER_HEAD = "e" * 40


def check(name: str, sha: str, *, status: str = "completed", conclusion: str = "success"):
    return {
        "name": name,
        "head_sha": sha,
        "status": status,
        "conclusion": conclusion,
        "updated_at": "2026-10-19T00:00:00Z",
    }


def pull_request(
    number: int,
    merge_sha: str,
    head_sha: str,
    labels: list[str] | None = None,
    *,
    merged: bool = True,
    base: str = "main",
):
    return {
        "number": number,
        "merged_at": "2026-10-19T00:00:00Z" if merged else None,
        "merge_commit_sha": merge_sha,
        "head": {"sha": head_sha},
        "base": {"ref": base},
        "labels": [{"name": label} for label in labels or []],
    }


class FakeGit:
    def __init__(self, paths=None, *, ancestor=True, tags=None):
        self.paths = paths or ["sdks/swift/Sources/LokiKit/Logger.swift"]
        self.ancestor = ancestor
        self.tag_map = tags or {"v0.2.0": BASELINE}
        self.commits = [CANDIDATE]
        self.pulls = {}
        self.local_tag = False
        self.remote_tag = False
        self.remote_commit = CANDIDATE
        self.remote_branch = CANDIDATE
        self.created_tags = []
        self.pushed_tags = []
        self.fetched = False

    def current_sha(self):
        return CANDIDATE

    def tags(self):
        return list(self.tag_map)

    def tag_commit(self, tag):
        return self.tag_map[tag]

    def is_ancestor(self, ancestor, descendant):
        return self.ancestor

    def changed_paths(self, baseline, candidate):
        return self.paths

    def first_parent_commits(self, baseline, candidate):
        return self.commits

    def fetch_default_branch(self, default_branch):
        self.fetched = True

    def ref_commit(self, ref):
        return self.remote_branch

    def ref_exists(self, ref):
        return self.local_tag

    def remote_tag_exists(self, tag, token=None):
        return self.remote_tag

    def create_annotated_tag(self, tag, candidate):
        self.created_tags.append((tag, candidate))

    def push_tag(self, tag, token=None):
        self.pushed_tags.append(tag)

    def remote_tag_commit(self, tag, token=None):
        return self.remote_commit


class FakeGitHub:
    def __init__(self, *, labels=None):
        self.candidate_pr = pull_request(35, CANDIDATE, PR_HEAD, labels)
        self.prs = {CANDIDATE: [self.candidate_pr]}
        self.checks = {
            CANDIDATE: [check(QUALITY_CHECK, CANDIDATE)],
            PR_HEAD: [check(CODEX_CHECK, PR_HEAD)],
        }

    def check_runs(self, sha):
        return self.checks.get(sha, [])

    def pulls_for_commit(self, sha):
        return self.prs.get(sha, [])


class ReleaseAssessmentTests(unittest.TestCase):
    def setUp(self):
        self.git = FakeGit()
        self.github = FakeGitHub()

    def assess(self):
        return assess_release(self.git, self.github, CANDIDATE, "main")

    def test_no_tag_fails_closed(self):
        self.git.tag_map = {}
        with self.assertRaisesRegex(ReleaseError, "No vX.Y.Z"):
            self.assess()

    def test_non_ancestor_baseline_fails_closed(self):
        self.git.ancestor = False
        with self.assertRaisesRegex(ReleaseError, "not an ancestor"):
            self.assess()

    def test_docs_only_change_is_not_publishable(self):
        self.git.paths = ["docs/automated-release.md"]
        result = self.assess()
        self.assertFalse(result.publishable)
        self.assertEqual(result.version, "v0.2.1")

    def test_swift_change_uses_patch_version(self):
        result = self.assess()
        self.assertTrue(result.publishable)
        self.assertEqual(result.version, "v0.2.1")

    def test_release_minor_label_bumps_minor(self):
        minor_pr = pull_request(34, OTHER_COMMIT, OTHER_HEAD, ["release:minor"])
        self.git.commits = [OTHER_COMMIT, CANDIDATE]
        self.github.prs[OTHER_COMMIT] = [minor_pr]
        result = self.assess()
        self.assertEqual(result.version, "v0.3.0")

    def test_breaking_label_requires_owner_decision(self):
        self.github.candidate_pr["labels"] = [{"name": "breaking"}]
        result = self.assess()
        self.assertFalse(result.publishable)
        self.assertTrue(result.owner_decision_required)

    def test_check_failures_missing_pending_failed_and_wrong_sha_fail(self):
        cases = [
            ("missing", []),
            ("pending", [check(QUALITY_CHECK, CANDIDATE, status="in_progress", conclusion=None)]),
            ("failed", [check(QUALITY_CHECK, CANDIDATE, conclusion="failure")]),
            ("wrong SHA", [check(QUALITY_CHECK, OTHER_COMMIT)]),
        ]
        for label, checks in cases:
            with self.subTest(label=label):
                self.github.checks[CANDIDATE] = checks
                with self.assertRaises(ReleaseError):
                    self.assess()
                self.github.checks[CANDIDATE] = [check(QUALITY_CHECK, CANDIDATE)]

    def test_no_associated_pr_fails(self):
        self.github.prs[CANDIDATE] = []
        with self.assertRaisesRegex(ReleaseError, "exactly one"):
            self.assess()

    def test_unmerged_pr_fails(self):
        self.github.prs[CANDIDATE] = [pull_request(35, CANDIDATE, PR_HEAD, merged=False)]
        with self.assertRaisesRegex(ReleaseError, "not merged"):
            self.assess()

    def test_merge_sha_mismatch_fails(self):
        self.github.prs[CANDIDATE] = [pull_request(35, OTHER_COMMIT, PR_HEAD)]
        with self.assertRaisesRegex(ReleaseError, "different merge"):
            self.assess()

    def test_pr_head_codex_gate_must_succeed(self):
        self.github.checks[PR_HEAD] = [check(CODEX_CHECK, PR_HEAD, conclusion="failure")]
        with self.assertRaisesRegex(ReleaseError, "not successful"):
            self.assess()

    def test_pr_head_codex_missing_pending_and_wrong_sha_fail(self):
        cases = [
            ("missing", []),
            ("pending", [check(CODEX_CHECK, PR_HEAD, status="in_progress", conclusion=None)]),
            ("wrong SHA", [check(CODEX_CHECK, OTHER_COMMIT)]),
        ]
        for label, checks in cases:
            with self.subTest(label=label):
                self.github.checks[PR_HEAD] = checks
                with self.assertRaises(ReleaseError):
                    self.assess()
                self.github.checks[PR_HEAD] = [check(CODEX_CHECK, PR_HEAD)]


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.git = FakeGit()
        self.github = FakeGitHub()
        self.environment = {
            "CANDIDATE": CANDIDATE,
            "GITHUB_REPOSITORY": "LeePepe/shared-telemetry",
            "DEFAULT_BRANCH": "main",
            "VERSION": "v0.2.1",
        }

    def run_publish(self):
        with mock.patch.dict(os.environ, self.environment, clear=False), mock.patch.object(
            publish_adapter, "runtime", return_value=(self.git, self.github, CANDIDATE, "main")
        ), contextlib.redirect_stderr(io.StringIO()) as error:
            result = publish_adapter.publish()
        return result, error.getvalue()

    def test_existing_tag_is_refused(self):
        self.git.remote_tag = True
        result, error = self.run_publish()
        self.assertEqual(result, 1)
        self.assertIn("already exists", error)
        self.assertEqual(self.git.created_tags, [])

    def test_readback_mismatch_fails_after_push(self):
        self.git.remote_commit = OTHER_COMMIT
        result, error = self.run_publish()
        self.assertEqual(result, 1)
        self.assertIn("read-back", error)
        self.assertEqual(self.git.pushed_tags, ["v0.2.1"])

    def test_branch_advance_is_refused_before_tag_creation(self):
        self.git.remote_branch = OTHER_COMMIT
        result, error = self.run_publish()
        self.assertEqual(result, 1)
        self.assertIn("default-branch tip", error)
        self.assertEqual(self.git.created_tags, [])


if __name__ == "__main__":
    unittest.main()
