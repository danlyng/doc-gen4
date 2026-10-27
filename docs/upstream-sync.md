# Upstream release synchronization

The **Sync upstream release tags** workflow checks `leanprover/doc-gen4` hourly at minute 23 and can also be dispatched on `main`. A release means a tag named `vMAJOR.MINOR.PATCH` or `vMAJOR.MINOR.PATCH-rcN`; GitHub Releases are not required. An upstream repository's tag events cannot directly trigger a workflow in this fork, so this uses polling. GitHub schedules can be delayed and public-repository schedules can be disabled after 60 days without activity; check the Actions page if the schedule stops. No Mac daemon, external agent service, personal token, or new persistent credential is installed.

The initial ledger in `.github/upstream-sync.json` explicitly maps upstream `v4.36.0-rc1` at `0656b7ebd305f089c8d6bd8684a0797f19414cc2` to the fork's corresponding release at `20c7b51d6e98efd23d5d4e1bb94d28847b17384e`. The fork's historical tag SHAs intentionally differ from upstream. Tag-name presence is never interpreted as proof that main contains the new release, and differing SHAs are never interpreted as pending releases.

The ledger pins all initially observed upstream release tag objects. Local runs also persist every observation in `.git/upstream-sync-tags.json`, even when preparation fails. On fresh GitHub runners, any failed, canceled, or timed-out sync freezes automatic retries. A maintainer must inspect the original artifact and acknowledge its exact `TAG@OID` in `expected_release` before resuming; rerunning the same Actions run without that pin is rejected. This prevents a failed attempt from silently forgetting an observed tag identity. Artifacts include `observed-tags.json` before cherry-picking. If evidence has expired, review upstream tag history manually before acknowledging a retry. Each successful sync records newly observed objects, the release's peeled commit, and the captured fork main. Removed/replaced pinned tags, newly backfilled older releases, missing/moved fork baseline tags, divergent histories, and ranges containing merges stop for review. A replacement of an entirely unobserved tag between polling runs cannot be detected. Protect upstream and fork release tags against changes if stronger immutability is needed. Never edit an existing release tag to repair a failed run.

## Normal operation

1. Prepare the oldest pending version, sorting version numbers and RC numbers numerically, with the final release after its RCs. Missed releases are processed one per successful run. Work is isolated from the controller checkout. Upstream tags are fetched without force into `refs/upstream-tags/origin/*`, never `refs/tags/*`.
2. Require the next fork tag to be absent. Cherry-pick every commit in the upstream range with `-x`, preserving empty commits. Stop on any conflict; no `ours`, `theirs`, or automatic merge-mainline choice is used. Require the release's toolchain. Dependency changes come from the upstream cherry-picks; compatibility fixes must use Lake and pass validation. Changes to trusted workflows, test scripts, controller files, Git attributes, or submodules require separate review and controller deployment before retrying.
3. Record the ledger in a final commit and upload an immutable candidate bundle. The validation job runs without publishing credentials, using a trusted copy of `scripts/upstream-sync/validate.sh`. It removes build output, runs `lake build --wfail`, serial and two-thread batch multi-library regressions, pruning, batch database/HTML equivalence, Verso module docs, and a clean docs build plus query/file-list comparison. Core equation generation remains enabled as in existing CI. Lean/doc-gen workers are capped at four, while the extra multi-library batch run uses two workers. The batch-equivalence script retains its existing behavior: core equations disabled during core setup, and fixture equations enabled and compared. It requires an unchanged candidate commit and clean tracked/untracked tree, then writes a receipt for that exact SHA.
4. Only after successful validation, a separate publishing job receives an ephemeral repository `GITHUB_TOKEN` with `contents: write`. It executes the trusted main controller, verifies the bundle, ledger, receipt, upstream pins, ancestry, unchanged main and absent new tag. It publishes the tested commit to main and the new lightweight fork tag in **one `git push --atomic`**, with no force options and no separate-push fallback. A trusted pre-push hook verifies Git's advertised old OIDs, including tag absence. The server transaction rejects races after advertisement. Both remote refs are checked after the push, including a failed push with an uncertain outcome. A retry recognizes success only when both refs equal the tested commit.

Workflow concurrency serializes complete prepare/test/publish runs without canceling a release in progress. Local invocations also take a nonblocking repository lock. Ordinary changes to main are not blocked: any concurrent advancement invalidates the candidate, requiring preparation and all tests again. Branch or tag protection can reject the final atomic push; the workflow never bypasses protection.

The publishing token's push will not trigger ordinary push CI. The release's authoritative checks are the validation job in this workflow, at the exact commit published. Automation deployment with the user's existing authentication does trigger ordinary push CI. The read-only `Upstream sync safeguards` workflow tests the controller on pushes and PRs.

## Conflict resolution

A failed preparation publishes no branch, main, or tag. Download the `upstream-sync-plan` artifact from the failed run. It contains `plan.json`, `observed-tags.json`, `resolution.bundle`, `conflict.patch`, and `conflicts.txt`. Artifacts expire after 30 days; the run can be repeated to regenerate them. The bundle retains successful picks and the upstream objects; it does not pretend that an unresolved index is a commit.

Create a disposable checkout:

```sh
git clone resolution.bundle doc-gen4-resolution
cd doc-gen4-resolution
git switch sync/vX.Y.Z-rcN
git remote set-url origin https://github.com/danlyng/doc-gen4.git
```

Read `plan.json` and cherry-pick `pending_commits` in their listed order with `git cherry-pick --allow-empty --keep-redundant-commits -x COMMIT`. Resolve each conflict, preserving fork features, then `git add` and `git cherry-pick --continue`. The first pending commit must be retried: the bundle saves the commit before the conflict. Do not apply `conflict.patch` blindly; it includes diagnostic conflict markers. Do not edit the ledger, trusted tests, or workflow/controller definitions. Adopt the upstream `lean-toolchain`; if dependencies need compatibility changes, use `lake update PACKAGE` rather than hand-editing dependency revisions. Inspect the resulting manifest and source changes. Commits added to address compatibility are allowed, but all original cherry-pick trailers must remain in order exactly once.

Push the reviewed resolution to `refs/heads/sync/vX.Y.Z-rcN`. If opening a PR for review, open it as a **draft** and do not merge it into main: the sync workflow must test and publish main plus the release tag atomically. Dispatch **Sync upstream release tags** from `main` with `resolved_ref` set to that exact full branch ref and `expected_release` set to `TAG@OID`, using the original `tag` and raw `upstream_oid` from the failed run’s `plan.json` (or `observed-tags.json` if preparation stopped earlier). Do not substitute a new OID after a tag replacement. A transient failure without conflicts can be retried with the same `expected_release` and no `resolved_ref`. The retry gate rejects a missing/changed acknowledged tag or a different next version. It fetches the resolution, validates it against current main and the pinned upstream range, adds the ledger, and runs all tests before publishing. If main advanced, re-create or rebase the resolution onto current main and repeat the complete gate. A maintainer (or an explicitly authorized local Codex task) performs semantic conflict resolution; autonomous agent resolution is not enabled, and no external agent credentials or services are configured.

## Local use and tests

Run `python3 -m unittest discover -s test/upstream-sync -v` for network-free integration tests using real repositories and pushes. For a local production attempt, use an isolated, clean checkout of current fork main:

```sh
python3 scripts/upstream-sync/sync.py prepare --output /tmp/docgen-sync-ATTEMPT
# If status is candidate:
bash scripts/upstream-sync/validate.sh /tmp/docgen-sync-ATTEMPT/work /tmp/docgen-sync-ATTEMPT/validated.json
python3 scripts/upstream-sync/sync.py publish --output /tmp/docgen-sync-ATTEMPT
```

Use a fresh output directory for every attempt. The command-line entry point fixes both production repository URLs; test fixtures inject local repository paths through Python only. Publication requires existing authorized Git authentication. Do not reuse a validation receipt after altering the candidate, and do not retry an uncertain push until both remote refs have been inspected. When GitHub disables the schedule in a fork, enable this specific workflow in Actions; no global workflow permission expansion or persistent secret is necessary.
