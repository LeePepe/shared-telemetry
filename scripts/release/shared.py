"""Standard-library release logic shared by the prepare and publish steps."""

from __future__ import annotations

import json
import os
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Iterable, Mapping, Sequence


RELEASE_TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
SHA = re.compile(r"^[0-9a-f]{40}$")
QUALITY_CHECK = "quality / aggregate"
CODEX_CHECK = "codex-review-gate"
RELEASE_CONTENT = ("Package.swift", "Package.resolved", "sdks/swift/Sources/")


class ReleaseError(RuntimeError):
    """A fail-closed release decision or adapter error."""


@dataclass(frozen=True)
class ReleaseAssessment:
    candidate: str
    baseline_tag: str
    baseline: str
    publishable: bool
    version: str
    candidate_pr_number: int
    pr_head_sha: str
    required_checks: str = "success"
    owner_decision_required: bool = False


def parse_release_tag(tag: str) -> tuple[int, int, int] | None:
    match = RELEASE_TAG.fullmatch(tag)
    return tuple(int(part) for part in match.groups()) if match else None


def highest_release_tag(tags: Iterable[str]) -> tuple[str, tuple[int, int, int]]:
    parsed = [(tag, version) for tag in tags if (version := parse_release_tag(tag))]
    if not parsed:
        raise ReleaseError("No vX.Y.Z release tag exists; refusing to select a baseline.")
    return max(parsed, key=lambda item: item[1])


def _check_sort_key(check: Mapping[str, Any]) -> tuple[str, str]:
    timestamp = (
        check.get("updated_at")
        or check.get("completed_at")
        or check.get("started_at")
        or ""
    )
    return str(timestamp), str(check.get("id", ""))


def latest_check(
    checks: Sequence[Mapping[str, Any]], name: str, expected_sha: str
) -> Mapping[str, Any]:
    named = [check for check in checks if check.get("name") == name]
    if not named:
        raise ReleaseError(f"Required check is missing: {name}.")
    latest = max(named, key=_check_sort_key)
    if latest.get("head_sha") != expected_sha:
        raise ReleaseError(f"Required check has the wrong SHA: {name}.")
    return latest


def require_success(
    checks: Sequence[Mapping[str, Any]], name: str, expected_sha: str
) -> None:
    check = latest_check(checks, name, expected_sha)
    if check.get("status") != "completed" or check.get("conclusion") != "success":
        raise ReleaseError(f"Required check is not successful: {name}.")


def labels_for(pr: Mapping[str, Any]) -> set[str]:
    return {
        str(label.get("name"))
        for label in pr.get("labels", [])
        if isinstance(label, Mapping) and label.get("name")
    }


def bumped_version(
    baseline_tag: str, pull_requests: Iterable[Mapping[str, Any]]
) -> tuple[str, bool]:
    version = parse_release_tag(baseline_tag)
    if version is None:
        raise ReleaseError(f"Invalid release baseline tag: {baseline_tag}.")
    major, minor, patch = version
    labels = {label for pr in pull_requests for label in labels_for(pr)}
    if "release:minor" in labels:
        next_version = (major, minor + 1, 0)
    else:
        next_version = (major, minor, patch + 1)
    return "v{}.{}.{}".format(*next_version), "breaking" not in labels


def has_release_content(paths: Iterable[str]) -> bool:
    return any(
        path in RELEASE_CONTENT or path.startswith(RELEASE_CONTENT[2])
        for path in paths
    )


def _pr_number(pr: Mapping[str, Any]) -> int | None:
    number = pr.get("number")
    return int(number) if isinstance(number, int) or str(number).isdigit() else None


def _is_merged_into(pr: Mapping[str, Any], default_branch: str) -> bool:
    base = pr.get("base") or {}
    return bool(pr.get("merged_at")) and base.get("ref") == default_branch


def candidate_pull_request(
    github: "GitHubClient", candidate: str, default_branch: str
) -> Mapping[str, Any]:
    pull_requests = github.pulls_for_commit(candidate)
    if len(pull_requests) != 1:
        raise ReleaseError(
            "Candidate must be associated with exactly one pull request into the default branch."
        )
    pr = pull_requests[0]
    if not _is_merged_into(pr, default_branch):
        raise ReleaseError("Candidate pull request is not merged into the default branch.")
    if pr.get("merge_commit_sha") != candidate:
        raise ReleaseError("Candidate pull request has a different merge commit SHA.")
    head_sha = (pr.get("head") or {}).get("sha")
    if not isinstance(head_sha, str) or not SHA.fullmatch(head_sha):
        raise ReleaseError("Candidate pull request has no valid final head SHA.")
    require_success(github.check_runs(head_sha), CODEX_CHECK, head_sha)
    return pr


def merged_pull_requests_in_range(
    git: "GitRepository",
    github: "GitHubClient",
    baseline: str,
    candidate: str,
    default_branch: str,
    candidate_pr: Mapping[str, Any],
) -> list[Mapping[str, Any]]:
    """Collect unique merged PRs represented by first-parent commits in the range."""
    collected: dict[int, Mapping[str, Any]] = {}
    for commit in git.first_parent_commits(baseline, candidate):
        for pr in github.pulls_for_commit(commit):
            number = _pr_number(pr)
            if number is not None and _is_merged_into(pr, default_branch):
                collected[number] = pr
    number = _pr_number(candidate_pr)
    if number is not None:
        collected[number] = candidate_pr
    return list(collected.values())


def assess_release(
    git: "GitRepository",
    github: "GitHubClient",
    candidate: str,
    default_branch: str,
) -> ReleaseAssessment:
    if not SHA.fullmatch(candidate):
        raise ReleaseError("Release candidate is not a full commit SHA.")
    current_sha = git.current_sha()
    if current_sha != candidate:
        raise ReleaseError("Checked-out revision is not the admitted release candidate.")

    baseline_tag, _ = highest_release_tag(git.tags())
    baseline = git.tag_commit(baseline_tag)
    if not git.is_ancestor(baseline, candidate):
        raise ReleaseError("Release baseline is not an ancestor of the candidate.")

    require_success(github.check_runs(candidate), QUALITY_CHECK, candidate)
    candidate_pr = candidate_pull_request(github, candidate, default_branch)
    pull_requests = merged_pull_requests_in_range(
        git, github, baseline, candidate, default_branch, candidate_pr
    )
    version, version_publishable = bumped_version(baseline_tag, pull_requests)
    publishable = version_publishable and has_release_content(
        git.changed_paths(baseline, candidate)
    )
    number = _pr_number(candidate_pr)
    if number is None:
        raise ReleaseError("Candidate pull request has no number.")
    return ReleaseAssessment(
        candidate=candidate,
        baseline_tag=baseline_tag,
        baseline=baseline,
        publishable=publishable,
        version=version,
        candidate_pr_number=number,
        pr_head_sha=(candidate_pr["head"]["sha"]),
        owner_decision_required=not version_publishable,
    )


class GitRepository:
    """Small subprocess adapter kept injectable for fixture tests."""

    def __init__(self, cwd: str | None = None) -> None:
        self.cwd = cwd

    def _run(self, args: Sequence[str], check: bool = True) -> str:
        result = subprocess.run(
            ["git", *args],
            cwd=self.cwd,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if check and result.returncode:
            raise ReleaseError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
        return result.stdout.strip()

    def current_sha(self) -> str:
        return self._run(["rev-parse", "HEAD"])

    def tags(self) -> list[str]:
        output = self._run(["tag", "--list", "v[0-9]*.[0-9]*.[0-9]*"])
        return output.splitlines() if output else []

    def tag_commit(self, tag: str) -> str:
        return self._run(["rev-list", "-n", "1", f"{tag}^{{}}"])

    def is_ancestor(self, ancestor: str, descendant: str) -> bool:
        result = subprocess.run(
            ["git", "merge-base", "--is-ancestor", ancestor, descendant],
            cwd=self.cwd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        return result.returncode == 0

    def changed_paths(self, baseline: str, candidate: str) -> list[str]:
        output = self._run(["diff", "--name-only", baseline, candidate])
        return output.splitlines() if output else []

    def first_parent_commits(self, baseline: str, candidate: str) -> list[str]:
        output = self._run(["rev-list", "--first-parent", "--reverse", f"{baseline}..{candidate}"])
        return output.splitlines() if output else []

    def fetch_default_branch(self, default_branch: str) -> None:
        self._run(
            [
                "fetch",
                "--no-tags",
                "origin",
                f"refs/heads/{default_branch}:refs/remotes/origin/{default_branch}",
            ]
        )

    def ref_commit(self, ref: str) -> str:
        return self._run(["rev-parse", ref])

    def ref_exists(self, ref: str) -> bool:
        result = subprocess.run(
            ["git", "rev-parse", "--verify", "--quiet", ref],
            cwd=self.cwd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        return result.returncode == 0

    def remote_tag_exists(self, tag: str, token: str | None = None) -> bool:
        output = self._remote_ls(f"refs/tags/{tag}", token)
        return bool(output)

    def create_annotated_tag(self, tag: str, candidate: str) -> None:
        self._run(
            [
                "-c",
                "user.name=github-actions[bot]",
                "-c",
                "user.email=41898282+github-actions[bot]@users.noreply.github.com",
                "tag",
                "-a",
                tag,
                candidate,
                "-m",
                f"Release {tag}",
            ]
        )

    def push_tag(self, tag: str, token: str | None = None) -> None:
        self._run_with_auth(["push", "origin", f"refs/tags/{tag}"], token)

    def remote_tag_commit(self, tag: str, token: str | None = None) -> str:
        dereferenced = self._remote_ls(f"refs/tags/{tag}^{{}}", token)
        output = dereferenced or self._remote_ls(f"refs/tags/{tag}", token)
        if not output:
            raise ReleaseError("Remote tag read-back returned no ref.")
        return output.split()[0]

    def _remote_ls(self, ref: str, token: str | None = None) -> str:
        return self._run_with_auth(["ls-remote", "origin", ref], token)

    def _run_with_auth(self, args: Sequence[str], token: str | None) -> str:
        if not token:
            return self._run(args)
        result = subprocess.run(
            ["git", "-c", f"http.extraHeader=Authorization: Bearer {token}", *args],
            cwd=self.cwd,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode:
            raise ReleaseError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
        return result.stdout.strip()


class GitHubClient:
    """Minimal GitHub REST client using only Python's standard library."""

    def __init__(
        self,
        repository: str,
        token: str | None,
        api_url: str = "https://api.github.com",
    ) -> None:
        self.repository = repository
        self.token = token
        self.api_url = api_url.rstrip("/")

    def _get(self, path: str, params: Mapping[str, str] | None = None) -> Any:
        query = urllib.parse.urlencode(params or {})
        url = f"{self.api_url}{path}" + (f"?{query}" if query else "")
        request = urllib.request.Request(
            url,
            headers={
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                **({"Authorization": f"Bearer {self.token}"} if self.token else {}),
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as error:
            raise ReleaseError("GitHub API read failed for the release evidence.") from error

    def _paged(self, path: str, key: str | None) -> list[Mapping[str, Any]]:
        items: list[Mapping[str, Any]] = []
        page = 1
        while True:
            payload = self._get(path, {"per_page": "100", "page": str(page)})
            page_items = payload if key is None else payload.get(key, [])
            if not isinstance(page_items, list):
                raise ReleaseError("GitHub API returned an invalid release evidence shape.")
            items.extend(item for item in page_items if isinstance(item, Mapping))
            if len(page_items) < 100:
                return items
            page += 1

    def check_runs(self, sha: str) -> list[Mapping[str, Any]]:
        return self._paged(f"/repos/{self.repository}/commits/{sha}/check-runs", "check_runs")

    def pulls_for_commit(self, sha: str) -> list[Mapping[str, Any]]:
        return self._paged(f"/repos/{self.repository}/commits/{sha}/pulls", None)


def runtime() -> tuple[GitRepository, GitHubClient, str, str]:
    candidate = os.environ.get("CANDIDATE", "")
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    if not repository:
        raise ReleaseError("GITHUB_REPOSITORY is required for release evidence.")
    default_branch = os.environ.get("DEFAULT_BRANCH", "main")
    github = GitHubClient(
        repository=repository,
        token=os.environ.get("GITHUB_TOKEN"),
        api_url=os.environ.get("GITHUB_API_URL", "https://api.github.com"),
    )
    return GitRepository(), github, candidate, default_branch


def write_outputs(values: Mapping[str, object]) -> None:
    output_path = os.environ.get("GITHUB_OUTPUT")
    if not output_path:
        return
    with open(output_path, "a", encoding="utf-8") as output:
        for key, value in values.items():
            output.write(f"{key}={value}\n")


def append_summary(text: str) -> None:
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_path:
        return
    with open(summary_path, "a", encoding="utf-8") as summary:
        summary.write(text.rstrip() + "\n")
