"""Resolve the exact candidate, checks, baseline, content and version."""

from __future__ import annotations

import sys

try:  # Running as a file from Actions.
    from .shared import ReleaseError, assess_release, append_summary, runtime, write_outputs
except ImportError:  # pragma: no cover - exercised by the Actions entry point.
    from shared import ReleaseError, assess_release, append_summary, runtime, write_outputs


def prepare() -> int:
    try:
        git, github, candidate, default_branch = runtime()
        assessment = assess_release(git, github, candidate, default_branch)
        write_outputs(
            {
                "checked-sha": assessment.candidate,
                "required-checks": assessment.required_checks,
                "baseline": assessment.baseline,
                "publishable": str(assessment.publishable).lower(),
                "version": assessment.version,
                "candidate-pr": assessment.candidate_pr_number,
                "pr-head-sha": assessment.pr_head_sha,
            }
        )
        if not assessment.publishable:
            append_summary(
                "Release candidate contains a `breaking` PR label; the Owner decides whether to release."
                if assessment.owner_decision_required
                else f"Release candidate `{assessment.candidate}` has no publishable Swift content."
            )
        return 0
    except ReleaseError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(prepare())
