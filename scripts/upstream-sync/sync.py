#!/usr/bin/env python3
"""Release synchronization controller. Standard library only; never edits its checkout."""
import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys

FORK = "https://github.com/danlyng/doc-gen4.git"
UPSTREAM = "https://github.com/leanprover/doc-gen4.git"
STATE = ".github/upstream-sync.json"
TAG = re.compile(r"v(\d+)\.(\d+)\.(\d+)(?:-rc(\d+))?\Z")
SHA = re.compile(r"[0-9a-f]{40}\Z")


def run(*args, cwd=None, check=True):
    p = subprocess.run(args, cwd=cwd, text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, timeout=600)
    if check and p.returncode:
        raise RuntimeError(f"{args[0]} failed ({p.returncode}): {p.stderr.strip()}")
    return p


def git(repo, *args, check=True):
    return run("git", "-C", str(repo), *args, check=check).stdout.strip()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def version(tag):
    m = TAG.fullmatch(tag)
    require(m is not None, f"Unsupported release tag: {tag}")
    a, b, c, rc = m.groups()
    return (int(a), int(b), int(c), 1 if rc is None else 0, int(rc or 0))


def release_pin(value):
    tag, separator, oid = value.partition("@")
    require(separator and TAG.fullmatch(tag) and SHA.fullmatch(oid),
            "Expected release must be vX.Y.Z[-rcN]@<40-character upstream tag object OID>")
    return tag, oid


def check_history(history, current_id, attempt, expected):
    if expected:
        release_pin(expected)
        return
    require(str(attempt) == "1", "A rerun requires expected_release from the original attempt's artifact")
    previous = [r for r in history["workflow_runs"] if str(r["id"]) != str(current_id)
                and r.get("head_branch") == "main"
                and r.get("event") in ("schedule", "workflow_dispatch")
                and r.get("status") == "completed"]
    if previous:
        latest = max(previous, key=lambda r: (r.get("updated_at", ""), int(r["id"])))
        require(latest.get("conclusion") == "success",
                f"Previous sync run {latest['id']} did not succeed. Review its artifact and dispatch "
                "with expected_release=TAG@OID; automatic retries cannot forget a previously observed tag")


def remote_refs(url):
    rows = run("git", "ls-remote", "--refs", url).stdout.splitlines()
    return dict((ref, oid) for oid, ref in (row.split() for row in rows))


def tags(refs):
    return {ref.removeprefix("refs/tags/"): oid for ref, oid in refs.items()
            if ref.startswith("refs/tags/") and TAG.fullmatch(ref.removeprefix("refs/tags/"))}


def immutable(known, current):
    for tag, oid in known.items():
        require(current.get(tag) == oid,
                f"Pinned upstream tag removed or replaced: {tag}; investigate manually")


def ancestor(repo, older, newer):
    return run("git", "-C", str(repo), "merge-base", "--is-ancestor", older, newer,
               check=False).returncode == 0


def load_state(repo, rev):
    return json.loads(git(repo, "show", f"{rev}:{STATE}"))


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def protected(path):
    return (path.startswith((".github/", "test/", "scripts/upstream-sync/"))
            or path in ("AGENTS.md", ".gitattributes", ".gitmodules")) and path != STATE


def validate_candidate(repo, base, tip, commits, state):
    require(ancestor(repo, base, tip), "Candidate is not a fast-forward of captured main")
    require(not git(repo, "rev-list", "--merges", f"{base}..{tip}"), "Candidate contains merges")
    changed = git(repo, "diff", "--name-only", base, tip).splitlines()
    require(not any(protected(p) for p in changed),
            "Candidate changes trusted tests/controller/workflows; review and deploy these separately")
    bodies = git(repo, "log", "--reverse", "--format=%B", f"{base}..{tip}")
    applied = re.findall(r"^\(cherry picked from commit ([0-9a-f]{40})\)$", bodies, re.M)
    require(applied == commits, "Candidate must record every upstream cherry-pick, exactly once and in order (-x)")
    require(load_state(repo, tip) == state, "Resolution branch must not edit the release ledger")


class Controller:
    def __init__(self, repo, fork=FORK, upstream=UPSTREAM):
        self.repo = Path(repo).resolve()
        self.fork = fork
        self.upstream = upstream

    def prepare(self, output, resolved_ref=None, expected_release=None):
        expected = release_pin(expected_release) if expected_release else None
        require(not resolved_ref or expected, "A resolution branch requires the original expected_release=TAG@OID")
        out = Path(output).resolve()
        out.mkdir(parents=True, exist_ok=True)
        require(not (out / "plan.json").exists(), "Use a new output directory for every attempt")
        work = out / "work"
        require(not work.exists(), "Refusing to initialize an existing work directory; use a fresh attempt directory")
        git(out, "init", str(work))
        git(work, "config", "user.name", "doc-gen4 upstream sync")
        git(work, "config", "user.email", "upstream-sync@users.noreply.github.com")
        # No credential helper or hooks from the user's checkout are copied.
        git(work, "remote", "add", "origin", self.fork)
        git(work, "fetch", "--no-tags", "origin", "refs/heads/main:refs/remotes/fork/main")
        base = git(work, "rev-parse", "refs/remotes/fork/main")
        require(base == git(self.repo, "rev-parse", "HEAD"),
                "Controller checkout is stale; run the current main controller")
        state = load_state(work, base)
        before = tags(remote_refs(self.upstream))
        immutable(state["upstream_tags"], before)
        require(expected is None or before.get(expected[0]) == expected[1],
                "Acknowledged upstream tag identity is missing or changed")
        # The local controller must retain observations even when preparation or
        # tests fail. GitHub runners additionally use the failed-run tripwire.
        observed = Path(git(self.repo, "rev-parse", "--absolute-git-dir")) / "upstream-sync-tags.json"
        if observed.exists():
            immutable(json.loads(observed.read_text()), before)
        pending_observation = observed.with_suffix(".tmp")
        write_json(pending_observation, before)
        pending_observation.replace(observed)
        write_json(out / "observed-tags.json", before)
        last = state["last"]["tag"]
        require(before.get(last) == state["last"]["upstream_oid"], "Baseline upstream OID mismatch")
        fork_refs = remote_refs(self.fork)
        fork_last = fork_refs.get("refs/tags/" + last)
        require(fork_last is not None, "Fork baseline tag is missing")
        git(work, "fetch", "--no-tags", self.fork,
            f"refs/tags/{last}:refs/fork-release/{last}")
        require(git(work, "rev-parse", f"refs/fork-release/{last}") == fork_last,
                "Fork baseline tag changed while fetching")
        require(ancestor(work, f"refs/fork-release/{last}^{{commit}}", base),
                "Fork main no longer contains its last synchronized release")
        if last == state["baseline"]["tag"]:
            require(fork_last == state["baseline"]["fork_oid"], "Fork baseline tag was replaced")
        else:
            tagged = load_state(work, f"refs/fork-release/{last}")
            require(tagged["last"] == state["last"], "Fork release tag and ledger disagree")
        late = [t for t in before if t not in state["upstream_tags"] and version(t) <= version(last)]
        require(not late, f"Unexpected backfilled older release tags: {late}; review manually")
        pending = sorted((t for t in before if version(t) > version(last)), key=version)
        if not pending:
            write_json(out / "plan.json", {"status": "current", "base": base, "last": last})
            return "current"
        tag = pending[0]
        require(expected is None or expected == (tag, before[tag]),
                "Next upstream release differs from the acknowledged tag/OID; refusing changed tag identity")
        require("refs/tags/" + tag not in fork_refs, f"Fork tag already exists: {tag}; never replace it")
        # Explicit, non-forced fetch into a namespace that cannot collide with fork tags.
        git(work, "fetch", "--no-tags", self.upstream,
            "refs/tags/*:refs/upstream-tags/origin/*")
        for name, oid in before.items():
            require(git(work, "rev-parse", "refs/upstream-tags/origin/" + name) == oid,
                    f"Upstream tag changed while fetching: {name}")
        immutable(before, tags(remote_refs(self.upstream)))
        old = git(work, "rev-parse", f"refs/upstream-tags/origin/{last}^{{commit}}")
        new = git(work, "rev-parse", f"refs/upstream-tags/origin/{tag}^{{commit}}")
        require(old == state["last"]["upstream_commit"], "Baseline peeled commit mismatch")
        require(ancestor(work, old, new), "Upstream release history is not a descendant of baseline")
        require(not git(work, "rev-list", "--merges", f"{old}..{new}"),
                "Upstream range contains merges; explicit review of mainline is required")
        commits = git(work, "rev-list", "--reverse", "--topo-order", f"{old}..{new}").splitlines()
        plan = {"status": "preparing", "base": base, "tag": tag,
                "upstream_oid": before[tag], "upstream_commit": new,
                "commits": commits, "upstream_tags": before,
                "fork_baseline_tag": last, "fork_baseline_oid": fork_last}
        write_json(out / "plan.json", plan)
        branch = f"sync/{tag}"
        if resolved_ref:
            require(resolved_ref == f"refs/heads/{branch}", f"Resolution ref must be refs/heads/{branch}")
            git(work, "fetch", "--no-tags", self.fork, resolved_ref)
            git(work, "switch", "-c", branch, "FETCH_HEAD")
        else:
            git(work, "switch", "-c", branch, base)
            for i, commit in enumerate(commits):
                picked = run("git", "-C", str(work), "-c", "rerere.enabled=false", "cherry-pick",
                             "--allow-empty", "--keep-redundant-commits", "-x", commit, check=False)
                if picked.returncode:
                    plan.update(status="conflict", pending_commits=commits[i:])
                    write_json(out / "plan.json", plan)
                    (out / "conflict.patch").write_text(git(work, "diff", "--binary", "HEAD") + "\n")
                    (out / "conflicts.txt").write_text(git(work, "status", "--short") + "\n" + picked.stderr)
                    git(work, "bundle", "create", str(out / "resolution.bundle"), "--all")
                    raise RuntimeError(f"Cherry-pick stopped at {commit}; resolution.bundle and plan.json preserve progress")
        tip = git(work, "rev-parse", "HEAD")
        validate_candidate(work, base, tip, commits, state)
        require(git(work, "show", f"HEAD:lean-toolchain") ==
                git(work, "show", f"{new}:lean-toolchain"), "Candidate did not adopt upstream release toolchain")
        # Compatible dependency changes come from the release's cherry-picked manifest.
        # Additional compatibility fixes on resolution branches must use Lake, then pass the gate.
        state["upstream_tags"] = before
        state["last"] = {"tag": tag, "upstream_oid": before[tag], "upstream_commit": new,
                         "fork_base": base}
        write_json(work / STATE, state)
        git(work, "add", STATE)
        git(work, "commit", "-m", f"sync: record upstream {tag}")
        candidate = git(work, "rev-parse", "HEAD")
        plan.update(status="candidate", candidate=candidate)
        write_json(out / "plan.json", plan)
        git(work, "bundle", "create", str(out / "candidate.bundle"), f"refs/heads/{branch}")
        return "candidate"

    def publish(self, output):
        out = Path(output).resolve()
        plan = json.loads((out / "plan.json").read_text())
        require(plan["status"] == "candidate", "Only a tested candidate may be published")
        base, candidate, tag = (plan[k] for k in ("base", "candidate", "tag"))
        require(SHA.fullmatch(base) and SHA.fullmatch(candidate) and TAG.fullmatch(tag), "Invalid plan")
        receipt = json.loads((out / "validated.json").read_text())
        require(receipt == {"candidate": candidate, "gate": 1}, "Validation receipt does not match exact candidate")
        require(git(self.repo, "rev-parse", "HEAD") == base, "Publisher controller is not the captured main")
        git(self.repo, "fetch", "--no-tags", str(out / "candidate.bundle"),
            f"refs/heads/sync/{tag}:refs/sync-candidate/{tag}")
        require(git(self.repo, "rev-parse", f"refs/sync-candidate/{tag}") == candidate, "Bundle candidate mismatch")
        state = load_state(self.repo, base)
        immutable(state["upstream_tags"], plan["upstream_tags"])
        require(version(tag) > version(state["last"]["tag"]), "Candidate does not advance the release baseline")
        # Revalidate the imported graph without executing anything from it.
        require(git(self.repo, "rev-list", "--count", f"{candidate}^..{candidate}") == "1", "Invalid ledger commit")
        validate_candidate(self.repo, base, candidate + "^", plan["commits"], state)
        require(git(self.repo, "diff-tree", "--no-commit-id", "--name-only", "-r", candidate) == STATE,
                "Final commit must only record the release ledger")
        expected = json.loads(json.dumps(state))
        expected["upstream_tags"] = plan["upstream_tags"]
        expected["last"] = {"tag": tag, "upstream_oid": plan["upstream_oid"],
                            "upstream_commit": plan["upstream_commit"], "fork_base": base}
        require(load_state(self.repo, candidate) == expected, "Candidate ledger mismatch")
        current = remote_refs(self.fork)
        # Idempotent recovery after an interrupted/uncertain successful push.
        if current.get("refs/heads/main") == candidate and current.get("refs/tags/" + tag) == candidate:
            return "already-published"
        require(current.get("refs/heads/main") == base, "Fork main advanced; rebuild and retest from current main")
        require("refs/tags/" + tag not in current, "Fork tag already exists; refusing publication")
        require(current.get("refs/tags/" + plan["fork_baseline_tag"]) == plan["fork_baseline_oid"],
                "Fork baseline tag changed after preparation")
        immutable(plan["upstream_tags"], tags(remote_refs(self.upstream)))
        require(ancestor(self.repo, base, candidate), "Refusing non-fast-forward publication")
        # A pre-push hook validates the *advertised* old OIDs of both refs. Git's
        # receive transaction then compares these same OIDs on the server. This
        # closes the ls-remote/push race without --force or force-with-lease.
        hooks = out / "publish-hooks"
        hooks.mkdir(exist_ok=True)
        hook = hooks / "pre-push"
        hook.write_text("#!/usr/bin/env python3\nimport sys\n"
                        f"expected = {{'refs/heads/main': ({candidate!r}, {base!r}), "
                        f"'refs/tags/{tag}': ({candidate!r}, '0' * 40)}}\n"
                        "actual = {}\n"
                        "for line in sys.stdin:\n"
                        "    local_ref, local_oid, remote_ref, remote_oid = line.split()\n"
                        "    actual[remote_ref] = (local_oid, remote_oid)\n"
                        "if actual != expected:\n"
                        "    sys.exit('Remote changed during publication; rebuild and retest')\n")
        hook.chmod(0o755)
        try:
            pushed = run("git", "-C", str(self.repo), "-c", f"core.hooksPath={hooks}", "push", "--atomic",
                         self.fork, f"{candidate}:refs/heads/main", f"{candidate}:refs/tags/{tag}", check=False)
            push_error = pushed.stderr.strip()
        except (OSError, subprocess.SubprocessError) as exc:
            # A timeout/disconnect can happen after the server committed both refs.
            pushed, push_error = None, str(exc)
        try:
            after = remote_refs(self.fork)
        except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
            raise RuntimeError(f"Publication outcome uncertain; inspect remote main and {tag} before retrying: {exc}") from exc
        if after.get("refs/heads/main") == candidate and after.get("refs/tags/" + tag) == candidate:
            return "published"
        require(pushed is not None and pushed.returncode == 0,
                f"Atomic push failed; no separate-push fallback. Observed main={after.get('refs/heads/main')}, "
                f"tag={after.get('refs/tags/' + tag)}. {push_error}")
        raise RuntimeError("Remote refs do not both match candidate; outcome uncertain, inspect before retrying")


@contextlib.contextmanager
def lock(repo):
    path = Path(git(repo, "rev-parse", "--absolute-git-dir")) / "upstream-sync.lock"
    with path.open("w") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "publish", "check-history"))
    parser.add_argument("--output", help="New attempt directory outside the controller checkout")
    parser.add_argument("--repo", default=".")
    parser.add_argument("--resolved-ref", help="Reviewed refs/heads/sync/vX.Y.Z[-rcN] in the fork")
    parser.add_argument("--expected-release", help="Original TAG@OID acknowledgment for a reviewed retry")
    parser.add_argument("--history", help="GitHub workflow-runs JSON for the failure tripwire")
    args = parser.parse_args()
    try:
        require(not os.environ.get("GITHUB_REPOSITORY") or os.environ["GITHUB_REPOSITORY"] == "danlyng/doc-gen4",
                "This controller only publishes to danlyng/doc-gen4")
        require(not os.environ.get("GITHUB_REF") or os.environ["GITHUB_REF"] == "refs/heads/main",
                "Run this workflow from main only")
        if args.command == "check-history":
            require(args.history is not None and os.environ.get("GITHUB_RUN_ID"), "Workflow history and run ID are required")
            check_history(json.loads(Path(args.history).read_text()), os.environ["GITHUB_RUN_ID"],
                          os.environ.get("GITHUB_RUN_ATTEMPT", "1"), args.expected_release)
            print("history-clear")
            return 0
        require(args.output is not None, "--output is required for prepare and publish")
        with lock(args.repo):
            controller = Controller(args.repo)
            result = (controller.prepare(args.output, args.resolved_ref, args.expected_release) if args.command == "prepare"
                      else controller.publish(args.output))
        print(result)
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
                stream.write(f"status={result}\n")
    except (RuntimeError, OSError, subprocess.SubprocessError) as exc:
        print(f"upstream-sync: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
