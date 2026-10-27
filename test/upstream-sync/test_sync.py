"""Integration tests use real Git repositories and real atomic pushes, no network."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/upstream-sync/sync.py"
spec = importlib.util.spec_from_file_location("upstream_sync", SCRIPT)
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


class Releases(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.upstream = self.root / "upstream"
        self.fork = self.root / "fork.git"
        self.control = self.root / "control"
        self.upstream.mkdir()
        sync.git(self.upstream, "init", "-b", "main")
        self.identity(self.upstream)
        (self.upstream / "feature").write_text("upstream\n")
        (self.upstream / "lean-toolchain").write_text("leanprover/lean4:v4.36.0-rc1\n")
        self.old = self.commit(self.upstream, "initial")
        sync.git(self.upstream, "tag", "v4.36.0-rc1")
        sync.run("git", "clone", "--bare", str(self.upstream), str(self.fork))
        sync.run("git", "clone", str(self.fork), str(self.control))
        self.identity(self.control)
        (self.control / "fork-feature").write_text("preserve this feature\n")
        self.fork_release = self.commit(self.control, "fork-only feature")
        sync.git(self.control, "tag", "-f", "v4.36.0-rc1")
        # Fixture setup intentionally models the already-existing divergent tags.
        sync.git(self.control, "push", "--force", "origin", "refs/tags/v4.36.0-rc1")
        state = {"schema": 1,
                 "baseline": {"tag": "v4.36.0-rc1", "fork_oid": self.fork_release,
                              "upstream_oid": self.old},
                 "last": {"tag": "v4.36.0-rc1", "upstream_oid": self.old,
                          "upstream_commit": self.old},
                 "upstream_tags": {"v4.36.0-rc1": self.old}}
        (self.control / ".github").mkdir()
        sync.write_json(self.control / sync.STATE, state)
        self.base = self.commit(self.control, "pin baseline")
        sync.git(self.control, "push", "origin", "main")
        self.driver = sync.Controller(self.control, str(self.fork), str(self.upstream))

    def identity(self, repo):
        sync.git(repo, "config", "user.name", "Test")
        sync.git(repo, "config", "user.email", "test@example.invalid")

    def commit(self, repo, message):
        sync.git(repo, "add", ".")
        sync.git(repo, "commit", "-m", message)
        return sync.git(repo, "rev-parse", "HEAD")

    def release(self, tag="v4.36.0-rc2", annotated=False):
        (self.upstream / "feature").write_text(tag + "\n")
        (self.upstream / "lean-toolchain").write_text("leanprover/lean4:" + tag + "\n")
        oid = self.commit(self.upstream, "release " + tag)
        args = ("-a", tag, "-m", tag) if annotated else (tag,)
        sync.git(self.upstream, "tag", *args)
        return oid

    def prepare(self, name="attempt", resolved=None):
        out = self.root / name
        pin = None
        if resolved:
            tag = resolved.removeprefix("refs/heads/sync/")
            pin = tag + "@" + sync.git(self.upstream, "rev-parse", "refs/tags/" + tag)
        self.driver.prepare(out, resolved, pin)
        plan = json.loads((out / "plan.json").read_text())
        # Fixture contents aren't Lean projects. Simulate the external gate receipt
        # only to exercise real Git publication; production uses validate.sh.
        if plan["status"] == "candidate":
            sync.write_json(out / "validated.json", {"candidate": plan["candidate"], "gate": 1})
        return out, plan

    def assert_untouched(self):
        refs = sync.remote_refs(str(self.fork))
        self.assertEqual(refs["refs/heads/main"], self.base)
        self.assertNotIn("refs/tags/v4.36.0-rc2", refs)

    def test_no_release_despite_different_fork_tag_oid(self):
        out, plan = self.prepare()
        self.assertEqual(plan["status"], "current")
        self.assertFalse((out / "candidate.bundle").exists())
        self.assert_untouched()

    def test_clean_release_atomic_publish_and_idempotent_retry(self):
        self.release(annotated=True)
        out, plan = self.prepare()
        self.assertEqual(plan["status"], "candidate")
        self.assertEqual((out / "work/fork-feature").read_text(), "preserve this feature\n")
        self.assertNotIn("refs/tags/v4.36.0-rc2", sync.git(out / "work", "show-ref"))
        self.assertEqual(self.driver.publish(out), "published")
        refs = sync.remote_refs(str(self.fork))
        self.assertEqual(refs["refs/heads/main"], plan["candidate"])
        self.assertEqual(refs["refs/tags/v4.36.0-rc2"], plan["candidate"])
        self.assertEqual(self.driver.publish(out), "already-published")

    def test_missed_releases_are_numeric_and_one_at_a_time(self):
        self.release("v4.36.0-rc2")
        self.release("v4.36.0-rc10")
        self.release("v4.36.0")
        out, plan = self.prepare()
        self.assertEqual(plan["tag"], "v4.36.0-rc2")
        self.driver.publish(out)
        sync.git(self.control, "fetch", "origin", "main")
        sync.git(self.control, "switch", "--detach", "FETCH_HEAD")
        out2, plan2 = self.prepare("attempt2")
        self.assertEqual(plan2["tag"], "v4.36.0-rc10")
        self.driver.publish(out2)
        sync.git(self.control, "fetch", "origin", "main")
        sync.git(self.control, "switch", "--detach", "FETCH_HEAD")
        _, plan3 = self.prepare("attempt3")
        self.assertEqual(plan3["tag"], "v4.36.0")

    def test_replaced_and_deleted_upstream_tags_reject(self):
        self.release()
        sync.git(self.upstream, "tag", "-f", "v4.36.0-rc1")
        with self.assertRaisesRegex(RuntimeError, "removed or replaced"):
            self.prepare()
        sync.git(self.upstream, "tag", "-d", "v4.36.0-rc1")
        with self.assertRaisesRegex(RuntimeError, "removed or replaced"):
            self.prepare("deleted")
        self.assert_untouched()

    def test_failed_observation_is_pinned_across_attempts(self):
        (self.control / "feature").write_text("fork conflict\n")
        self.base = self.commit(self.control, "fork conflict")
        sync.git(self.control, "push", "origin", "main")
        self.release()
        with self.assertRaisesRegex(RuntimeError, "Cherry-pick stopped"):
            self.prepare()
        sync.git(self.upstream, "tag", "-f", "v4.36.0-rc2", self.old)
        with self.assertRaisesRegex(RuntimeError, "removed or replaced"):
            self.prepare("retry")
        self.assert_untouched()

    def test_reviewed_retry_must_match_tag_and_raw_oid(self):
        oid = self.release()
        with self.assertRaisesRegex(RuntimeError, "Acknowledged upstream tag identity"):
            self.driver.prepare(self.root / "bad-oid", expected_release="v4.36.0-rc2@" + self.old)
        with self.assertRaisesRegex(RuntimeError, "Acknowledged upstream tag identity"):
            self.driver.prepare(self.root / "bad-name", expected_release="v4.36.0-rc3@" + oid)
        self.assert_untouched()

    def test_existing_work_directory_is_preserved(self):
        work = self.root / "attempt/work"
        work.mkdir(parents=True)
        (work / "user-work").write_text("do not modify\n")
        with self.assertRaisesRegex(RuntimeError, "existing work directory"):
            self.prepare()
        self.assertEqual((work / "user-work").read_text(), "do not modify\n")
        self.assertFalse((work / ".git").exists())

    def test_backfilled_old_release_rejects(self):
        sync.git(self.upstream, "tag", "v4.35.9")
        with self.assertRaisesRegex(RuntimeError, "backfilled"):
            self.prepare()

    def test_existing_fork_tag_rejects_even_if_same_commit(self):
        oid = self.release()
        sync.git(self.control, "tag", "v4.36.0-rc2", self.base)
        sync.git(self.control, "push", "origin", "refs/tags/v4.36.0-rc2")
        with self.assertRaisesRegex(RuntimeError, "already exists"):
            self.prepare()

    def test_conflict_preserves_bundle_and_does_not_publish(self):
        (self.control / "feature").write_text("fork semantic change\n")
        self.base = self.commit(self.control, "fork semantic change")
        sync.git(self.control, "push", "origin", "main")
        self.release()
        with self.assertRaisesRegex(RuntimeError, "Cherry-pick stopped"):
            self.prepare()
        out = self.root / "attempt"
        plan = json.loads((out / "plan.json").read_text())
        self.assertEqual(plan["status"], "conflict")
        self.assertTrue((out / "resolution.bundle").exists())
        sync.git(self.control, "bundle", "verify", str(out / "resolution.bundle"))
        with self.assertRaisesRegex(RuntimeError, "Only a tested candidate"):
            self.driver.publish(out)
        self.assert_untouched()
        # Simulate a human resolving the exact stopped cherry-pick.
        work = out / "work"
        (work / "feature").write_text("fork semantic change plus release compatibility\n")
        sync.git(work, "add", "feature")
        sync.git(work, "-c", "core.editor=true", "cherry-pick", "--continue")
        sync.git(work, "push", str(self.fork), "HEAD:refs/heads/sync/v4.36.0-rc2")
        out2, resolved = self.prepare("resolved", "refs/heads/sync/v4.36.0-rc2")
        self.assertEqual(resolved["status"], "candidate")
        self.assertEqual(self.driver.publish(out2), "published")

    def test_upstream_cannot_modify_trusted_tests(self):
        (self.upstream / "test").mkdir()
        (self.upstream / "test/bypass.sh").write_text("exit 0\n")
        self.release()
        with self.assertRaisesRegex(RuntimeError, "trusted tests/controller"):
            self.prepare()
        self.assert_untouched()

    def test_resolution_cannot_omit_cherry_picks(self):
        self.release()
        sync.git(self.control, "push", str(self.fork), "HEAD:refs/heads/sync/v4.36.0-rc2")
        with self.assertRaisesRegex(RuntimeError, "every upstream cherry-pick"):
            self.prepare(resolved="refs/heads/sync/v4.36.0-rc2")

    def test_new_main_invalidates_candidate(self):
        self.release()
        out, plan = self.prepare()
        (self.control / "other-work").write_text("concurrent main change\n")
        advanced = self.commit(self.control, "concurrent work")
        sync.git(self.control, "push", "origin", "main")
        sync.git(self.control, "switch", "--detach", self.base)
        with self.assertRaisesRegex(RuntimeError, "main advanced"):
            self.driver.publish(out)
        self.assertEqual(sync.remote_refs(str(self.fork))["refs/heads/main"], advanced)
        self.assertNotIn("refs/tags/v4.36.0-rc2", sync.remote_refs(str(self.fork)))

    def test_tag_created_after_testing_rejects(self):
        self.release()
        out, plan = self.prepare()
        sync.git(self.control, "tag", "v4.36.0-rc2")
        sync.git(self.control, "push", "origin", "refs/tags/v4.36.0-rc2")
        with self.assertRaisesRegex(RuntimeError, "already exists"):
            self.driver.publish(out)

    def test_moved_upstream_after_testing_rejects(self):
        self.release()
        out, plan = self.prepare()
        sync.git(self.upstream, "tag", "-f", "v4.36.0-rc2", self.old)
        with self.assertRaisesRegex(RuntimeError, "removed or replaced"):
            self.driver.publish(out)
        self.assert_untouched()

    def test_server_rejects_tag_atomically(self):
        self.release()
        out, plan = self.prepare()
        hook = self.fork / "hooks/update"
        hook.write_text('#!/bin/sh\ncase "$1" in refs/tags/*) exit 1;; esac\n')
        hook.chmod(0o755)
        with self.assertRaisesRegex(RuntimeError, "Atomic push failed"):
            self.driver.publish(out)
        self.assert_untouched()

    def test_main_race_inside_server_receive_preserves_concurrent_work(self):
        self.release()
        out, plan = self.prepare()
        (self.control / "concurrent").write_text("preserve concurrent work\n")
        advanced = self.commit(self.control, "concurrent work")
        sync.git(self.control, "push", "origin", "HEAD:refs/heads/concurrent")
        sync.git(self.control, "switch", "--detach", self.base)
        hook = self.fork / "hooks/update"
        hook.write_text('#!/bin/sh\nif test "$1" = refs/heads/main; then\n'
                        f'  git update-ref refs/heads/main {advanced} {self.base} || exit 1\nfi\n')
        hook.chmod(0o755)
        with self.assertRaisesRegex(RuntimeError, "Atomic push failed"):
            self.driver.publish(out)
        refs = sync.remote_refs(str(self.fork))
        self.assertEqual(refs["refs/heads/main"], advanced)
        self.assertNotIn("refs/tags/v4.36.0-rc2", refs)

    def test_non_descendant_upstream_history_rejects(self):
        sync.git(self.upstream, "checkout", "--orphan", "replaced-history")
        (self.upstream / "feature").write_text("unrelated history\n")
        self.commit(self.upstream, "unrelated root")
        sync.git(self.upstream, "tag", "v4.36.0-rc2")
        with self.assertRaisesRegex(RuntimeError, "not a descendant"):
            self.prepare()
        self.assert_untouched()

    def test_merge_range_requires_explicit_mainline_review(self):
        sync.git(self.upstream, "switch", "-c", "side")
        (self.upstream / "side").write_text("side\n")
        self.commit(self.upstream, "side")
        sync.git(self.upstream, "switch", "main")
        (self.upstream / "mainline").write_text("mainline\n")
        self.commit(self.upstream, "mainline")
        sync.git(self.upstream, "merge", "--no-ff", "-m", "merge side", "side")
        sync.git(self.upstream, "tag", "v4.36.0-rc2")
        with self.assertRaisesRegex(RuntimeError, "range contains merges"):
            self.prepare()
        self.assert_untouched()

    def test_replaced_fork_baseline_tag_rejects(self):
        sync.git(self.control, "tag", "-f", "v4.36.0-rc1", self.base)
        sync.git(self.control, "push", "--force", "origin", "refs/tags/v4.36.0-rc1")
        with self.assertRaisesRegex(RuntimeError, "Fork baseline tag was replaced"):
            self.prepare()

    def test_remote_without_atomic_support_has_no_fallback(self):
        self.release()
        out, plan = self.prepare()
        sync.git(self.fork, "config", "receive.advertiseAtomic", "false")
        with self.assertRaisesRegex(RuntimeError, "Atomic push failed"):
            self.driver.publish(out)
        self.assert_untouched()

    def test_successful_push_then_timeout_verifies_both_refs(self):
        self.release()
        out, plan = self.prepare()
        original = sync.run
        def disconnected(*args, **kwargs):
            result = original(*args, **kwargs)
            if "push" in args and "--atomic" in args:
                raise subprocess.TimeoutExpired("git push", 600)
            return result
        with patch.object(sync, "run", side_effect=disconnected):
            self.assertEqual(self.driver.publish(out), "published")
        refs = sync.remote_refs(str(self.fork))
        self.assertEqual(refs["refs/heads/main"], plan["candidate"])
        self.assertEqual(refs["refs/tags/v4.36.0-rc2"], plan["candidate"])

    def test_push_timeout_without_execution_checks_remote_and_stops(self):
        self.release()
        out, plan = self.prepare()
        original = sync.run
        def timeout(*args, **kwargs):
            if "push" in args and "--atomic" in args:
                raise subprocess.TimeoutExpired("git push", 600)
            return original(*args, **kwargs)
        with patch.object(sync, "run", side_effect=timeout):
            with self.assertRaisesRegex(RuntimeError, "Atomic push failed.*Observed main="):
                self.driver.publish(out)
        self.assert_untouched()

    def test_fork_baseline_replaced_after_preparation_rejects(self):
        self.release()
        out, plan = self.prepare()
        sync.git(self.control, "tag", "-f", "v4.36.0-rc1", self.base)
        sync.git(self.control, "push", "--force", "origin", "refs/tags/v4.36.0-rc1")
        with self.assertRaisesRegex(RuntimeError, "baseline tag changed after"):
            self.driver.publish(out)

    def test_candidate_bundle_mismatch_rejects(self):
        self.release()
        out, plan = self.prepare()
        plan["candidate"] = self.base
        sync.write_json(out / "plan.json", plan)
        sync.write_json(out / "validated.json", {"candidate": self.base, "gate": 1})
        with self.assertRaisesRegex(RuntimeError, "Bundle candidate mismatch"):
            self.driver.publish(out)

    def test_validation_receipt_required_for_exact_candidate(self):
        self.release()
        out, plan = self.prepare()
        sync.write_json(out / "validated.json", {"candidate": self.base, "gate": 1})
        with self.assertRaisesRegex(RuntimeError, "Validation receipt"):
            self.driver.publish(out)
        self.assert_untouched()

    def test_advertised_ref_hook_rejects_races_and_existing_tag(self):
        self.release()
        out, plan = self.prepare()
        self.driver.publish(out)
        hook = out / "publish-hooks/pre-push"
        main = f"HEAD {plan['candidate']} refs/heads/main {self.base}\n"
        tag = f"HEAD {plan['candidate']} refs/tags/{plan['tag']} {'0' * 40}\n"
        for text, code in [(main + tag, 0), (main, 1), (tag, 1),
                           (main.replace(self.base, self.old) + tag, 1),
                           (main + tag.replace('0' * 40, plan['candidate']), 1)]:
            p = subprocess.run([str(hook)], input=text, text=True, capture_output=True)
            self.assertEqual(p.returncode, code, p.stderr)

    def test_local_run_lock(self):
        with sync.lock(self.control):
            with self.assertRaises(BlockingIOError):
                with sync.lock(self.control):
                    self.fail("Acquired a held lock")

    def test_version_order(self):
        self.assertLess(sync.version("v4.36.0-rc2"), sync.version("v4.36.0-rc10"))
        self.assertLess(sync.version("v4.36.0-rc10"), sync.version("v4.36.0"))
        self.assertLess(sync.version("v4.9.0"), sync.version("v4.10.0"))


class FailureHistory(unittest.TestCase):
    def history(self, conclusion="failure", branch="main"):
        return {"workflow_runs": [{"id": 1, "head_branch": branch, "event": "schedule",
                                   "status": "completed", "conclusion": conclusion}]}

    def test_initial_and_successful_history_pass(self):
        sync.check_history({"workflow_runs": []}, "2", "1", None)
        sync.check_history(self.history("success"), "2", "1", None)

    def test_failed_cancelled_and_timed_out_runs_freeze_automatic_retry(self):
        for conclusion in ("failure", "cancelled", "timed_out"):
            with self.assertRaisesRegex(RuntimeError, "Previous sync run"):
                sync.check_history(self.history(conclusion), "2", "1", None)

    def test_reviewed_pin_allows_retry_and_bad_pin_rejects(self):
        sync.check_history(self.history(), "2", "1", "v4.36.0-rc2@" + "a" * 40)
        with self.assertRaisesRegex(RuntimeError, "Expected release"):
            sync.check_history(self.history(), "2", "1", "rc2")

    def test_rerunning_same_run_requires_explicit_pin(self):
        with self.assertRaisesRegex(RuntimeError, "rerun requires"):
            sync.check_history({"workflow_runs": []}, "2", "2", None)

    def test_other_branch_success_cannot_clear_main_failure(self):
        history = self.history()
        other = self.history("success", "other")["workflow_runs"][0]
        other["id"] = 3
        history["workflow_runs"].append(other)
        with self.assertRaisesRegex(RuntimeError, "Previous sync run"):
            sync.check_history(history, "2", "1", None)


if __name__ == "__main__":
    unittest.main()
