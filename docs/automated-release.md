# Automated Swift release

This repository's release workflow is adapted from shared-ci v0.6.0 provider
SHA `0d8fcc0b5efb86711a921483ce0748bc19793add`.

## Release unit

The release unit is **LokiKit / SwiftPM**. A release is an annotated immutable
Git tag (`vX.Y.Z`) on the admitted candidate commit. Consumers resolve the
Swift package by the exact released version and source revision; this workflow
does not publish Web or Python artifacts.

## Candidate and baseline

The workflow wakes after a successful `ci` run for a same-repository push to
the default branch and checks out that run's exact `head_sha`. It requires the
latest `quality / aggregate` attempt on that candidate to succeed. The
candidate must also be the merge commit of exactly one merged PR into `main`.
That PR's final head must have a successful latest `codex-review-gate` attempt.
Missing, pending, failed, cancelled, skipped, ambiguous or wrong-SHA evidence
fails closed.

The baseline is the commit of the highest `vX.Y.Z` tag. No tag, or a baseline
that is not an ancestor of the candidate, is an error; the candidate is never
silently treated as its own baseline. The adapter examines the complete
`baseline..candidate` diff. Only a change to `Package.swift`,
`Package.resolved` or `sdks/swift/Sources/**` makes the range publishable.

## Version rule

The default bump is patch (`vX.Y.(Z+1)`). If any merged PR in the unreleased
range has the `release:minor` label, the bump is minor (`vX.(Y+1).0`). A
`breaking` label makes the candidate non-publishable and writes a job summary
stating that the Owner decides whether a breaking release is authorized.

The publisher rechecks the candidate evidence, baseline, that the default
branch still points at the candidate, its ancestry and tag absence immediately
before creating the annotated tag. It
refuses an existing tag or a race, never moves or deletes a tag, and reads the
remote tag back to confirm it points at the candidate.

## Owner decisions

Required checks and AI review protect changes to `.github/**` and
`scripts/verify`; merging does not require an approving review. The Owner
still decides whether to enable automatic tagging. A `breaking` label always pauses
publication for the Owner's decision; no release tag is created automatically
for that candidate.
