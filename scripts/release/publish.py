"""Create and verify the immutable annotated Swift release tag."""

from __future__ import annotations

import os
import sys

try:  # Running as a file from Actions.
    from .shared import ReleaseError, assess_release, runtime, write_outputs
except ImportError:  # pragma: no cover - exercised by the Actions entry point.
    from shared import ReleaseError, assess_release, runtime, write_outputs


def publish() -> int:
    try:
        git, github, candidate, default_branch = runtime()
        # Refresh the branch before the final evidence and tag-existence checks.
        git.fetch_default_branch(default_branch)
        assessment = assess_release(git, github, candidate, default_branch)
        expected_version = os.environ.get("VERSION", assessment.version)
        if expected_version != assessment.version:
            raise ReleaseError("The publish version does not match the final release assessment.")
        if not assessment.publishable:
            raise ReleaseError("The final release assessment is not publishable.")
        remote_branch = f"refs/remotes/origin/{default_branch}"
        if git.ref_commit(remote_branch) != candidate:
            raise ReleaseError("Candidate is no longer the default-branch tip.")
        if not git.is_ancestor(candidate, remote_branch):
            raise ReleaseError("Candidate is no longer an ancestor of the default branch.")

        tag = expected_version
        token = os.environ.get("GITHUB_TOKEN")
        if git.ref_exists(f"refs/tags/{tag}") or git.remote_tag_exists(tag, token):
            raise ReleaseError(f"Release tag already exists: {tag}.")

        git.create_annotated_tag(tag, candidate)
        git.push_tag(tag, token)
        if git.remote_tag_commit(tag, token) != candidate:
            raise ReleaseError("Remote tag read-back does not point at the candidate.")
        write_outputs(
            {
                "published-sha": candidate,
                "published-tag": tag,
                "verified-artifacts": "success",
            }
        )
        return 0
    except ReleaseError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(publish())
