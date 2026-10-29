"""Offline release transactions: real files/checkpoints, fake GitHub/Mix/Hex.

No test invokes signing tasks or reads a real signing key. Service doubles
model accepted writes followed by lost responses, which plain happy-path
command-list assertions cannot exercise.
"""
import contextlib
import copy
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("release_driver", ROOT / "scripts/release.py")
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


def tar(path, files):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as archive:
        for name, data in files.items():
            entry = tarfile.TarInfo(name)
            entry.size, entry.mode = len(data), 0o644
            archive.addfile(entry, io.BytesIO(data))
    path.write_bytes(gzip.compress(buffer.getvalue(), mtime=0) if str(path).endswith(".gz") else buffer.getvalue())


class World:
    sha = "a" * 40

    def __init__(self, base):
        self.base, self.calls = base, []
        self.fixture, self.candidate = base / "fixture", base / "candidate"
        self.fixture.mkdir(); self.candidate.mkdir()
        self.tagged = self.pushed = self.signed = self.published = self.dispatched = False
        self.hex, self.package_hash = None, None
        self.fail_after = None
        self.changed_draft = False
        self.new_attempt = False
        self.latest_override = None
        self.version_file = "0.12.0"
        self.source_files = {"VERSION": "0.12.0\n", "LICENSE": "license", "NOTICE": "notice",
                             ".github/release-notes.md": "macOS 15 or later",
                             "scripts/install.py": "installer", "scripts/install.sh": "installer shell",
                             "dist/lmx/upgrades/0.12.0.exs": "reviewed restart plan"}
        for name, body in self.source_files.items():
            path = self.fixture / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body)
        for dest, source in {"LICENSE": "LICENSE", "NOTICE": "NOTICE", "release-notes.md": ".github/release-notes.md",
                             "install.py": "scripts/install.py", "install.sh": "scripts/install.sh",
                             "upgrade-plan.exs": "dist/lmx/upgrades/0.12.0.exs"}.items():
            (self.candidate / dest).write_text(self.source_files[source])
        self.previous = {"schema_version": 1, "version": "0.11.0", "targets": {}}
        targets = {}
        header = struct.pack("<IiiIIIII", 0xfeedfacf, 0, 0, 0, 1, 24, 0, 0)
        macho = header + struct.pack("<IIIIII", 0x32, 24, 1, 15 << 16, 15 << 16, 0)
        for target in driver.TARGETS:
            info = {"target": target, "version": "0.12.0", "build_id": "b" * 64,
                    "native_id": "c" * 64, "dependency_id": "d" * 64, "config_id": "e" * 64,
                    "erts": "17.1", "elixir": "1.20.4", "dependencies": {}, "upgrade_from": [], "hot_modules": []}
            files = {"releases/0.12.0/release.json": json.dumps(info).encode()}
            if target.startswith("macos"):
                files["erts-17.1/bin/beam.smp"] = macho
            name = f"lmx_{target}.tar.gz"
            tar(self.candidate / name, files)
            current = dict(info, sha256=driver.sha256(self.candidate / name))
            old = dict(info, version="0.11.0", build_id="f" * 64)
            self.previous["targets"][target] = dict(old, sha256="0" * 64)
            targets[target] = current
            report = {"schema_version": 1, "target": target, "from": old, "to": current,
                      "previous_sha256": "0" * 64, "candidate_sha256": current["sha256"],
                      "plan_sha256": driver.sha256(self.candidate / "upgrade-plan.exs"),
                      "cold_boot": True, "tools_and_transcript_resume": True,
                      "restart_install": target != "windows", "windows_manual_restart": target == "windows"}
            (self.candidate / f"upgrade-report-{target}.json").write_text(json.dumps(report))
        (self.candidate / "update.json").write_text(json.dumps({"schema_version": 1, "version": "0.12.0", "targets": targets}))
        self.sums()

    def sums(self):
        entries = sorted(p for p in self.candidate.iterdir() if p.name != "SHA256SUMS")
        (self.candidate / "SHA256SUMS").write_text("".join(f"{driver.sha256(p)}  {p.name}\n" for p in entries))

    def run(self, workflow, event, branch, identifier):
        return {"id": identifier, "head_sha": self.sha, "event": event, "head_branch": branch,
                "run_attempt": 2 if self.new_attempt and identifier == 4 else 1,
                "status": "completed", "conclusion": "success", "path": ".github/workflows/" + workflow,
                "html_url": f"https://github.com/houllette/lemieux/actions/runs/{identifier}"}

    def api(self, endpoint, absent=False):
        if endpoint == "user":
            return {"login": "maintainer", "id": 123}
        if endpoint.endswith("/actions/workflows/ci.yml/runs?head_sha=" + self.sha + "&event=push&per_page=100"):
            return {"workflow_runs": [self.run("ci.yml", "push", "main", 1)]}
        if "/actions/workflows/public-readiness.yml/" in endpoint:
            return {"workflow_runs": [self.run("public-readiness.yml", "push", "main", 2)]}
        if "/actions/workflows/release.yml/" in endpoint:
            event = "workflow_dispatch" if "event=workflow_dispatch" in endpoint else "push"
            runs = [self.run("release.yml", event, "main" if event == "workflow_dispatch" else "v0.12.0", 3 if event == "workflow_dispatch" else 4)]
            return {"workflow_runs": runs if (self.dispatched if event == "workflow_dispatch" else self.pushed) else []}
        if endpoint.endswith("/releases/latest"):
            return {"tag_name": self.latest_override or ("v0.12.0" if self.published else "v0.11.0")}
        if endpoint.endswith("/releases/tags/v0.12.0"):
            if not self.published:
                raise driver.ReleaseError("HTTP/2.0 404 Not Found: tag lookup only returns published releases")
            return {"draft": not self.published, "prerelease": not self.published,
                    "html_url": "https://github.com/houllette/lemieux/releases/tag/v0.12.0"}
        if endpoint == "repos/" + driver.REPO:
            return {"private": False, "permissions": {"push": True}}
        if endpoint.endswith("/git/ref/heads/main"):
            return {"object": {"sha": self.sha}}
        raise AssertionError("Unexpected endpoint: " + endpoint)

    def __call__(self, args, cwd, capture=False):
        args = tuple(map(str, args)); self.calls.append(args)
        if args[:4] == ("git", "remote", "get-url", "origin"):
            return "git@github.com:houllette/lemieux.git"
        if args[:2] == ("git", "clone"):
            shutil.copytree(self.fixture, args[-1]); (Path(args[-1]) / ".git").mkdir(exist_ok=True); return ""
        if args[:3] == ("git", "tag", "--list"):
            return "v0.12.0" if self.tagged else ""
        if args[:2] == ("git", "rev-parse"):
            return self.sha
        if args[:2] == ("git", "ls-remote"):
            return "f" * 40 + "\trefs/tags/v0.12.0" if self.pushed else ""
        if args[:2] in (("git", "fetch"), ("git", "status")):
            return ""
        if args[:2] in (("git", "merge-base"), ("git", "switch")):
            return ""
        if args[:2] == ("git", "config"):
            return ""
        if args[:2] == ("git", "cat-file"):
            return "tag"
        if args[:3] == ("git", "tag", "-a"):
            self.tagged = True; return ""
        if args[:2] == ("git", "push"):
            if self.fail_after == "push-before":
                self.fail_after = None; raise driver.ReleaseError("push not accepted")
            self.pushed = True
            if self.fail_after == "push":
                self.fail_after = None; raise driver.ReleaseError("lost push response")
            return ""
        if args[:2] == ("git", "show"):
            return "public test key"
        if args[:2] == ("git", "ls-files"):
            return "\n".join(self.source_files)
        if args[:2] == ("mise", "install"):
            return ""
        if args[:4] == ("mise", "exec", "--", "mix"):
            task = args[4]
            if task == "run":
                marker = Path(cwd) / "_build/retained-compile"
                marker.parent.mkdir(exist_ok=True)
                marker.write_text("compiled")
                if self.fail_after == "bootstrap":
                    self.fail_after = None; raise KeyboardInterrupt()
                return ""
            if task in ("local.hex", "local.rebar", "deps.get", "run", "hex.user", "lmx.upgrade.check", "lmx.release.verify"):
                return ""
            if task == "lmx.release.sign_draft":
                self.signed = True; return ""
            if task == "hex.build":
                inner = self.base / "contents.tar.gz"
                tar(inner, {"VERSION": b"0.12.0\n"})
                tar(Path(args[-1]), {"contents.tar.gz": inner.read_bytes()})
                self.package_hash = driver.sha256(args[-1]); return ""
            if task == "hex.publish":
                if "--dry-run" in args:
                    return ""
                self.hex = {"version": "0.12.0", "checksum": self.package_hash, "has_docs": True, "retirement": None}
                if self.fail_after == "hex":
                    (Path(cwd) / "erl_crash.dump").write_text("throwaway diagnostic memory")
                    self.fail_after = None; raise driver.ReleaseError("lost Hex response")
                if self.fail_after == "replace":
                    self.changed_draft = True
                if self.fail_after == "attempt":
                    self.new_attempt = True
                return ""
        if args[:3] == ("gh", "workflow", "run"):
            self.dispatched = True; return ""
        if args[:3] == ("gh", "run", "download"):
            shutil.copytree(self.candidate, args[-1]); return ""
        if args[:3] == ("gh", "release", "download"):
            directory = Path(args[args.index("--dir") + 1])
            if args[3] == "v0.11.0":
                directory.mkdir()
                (directory / "update.json").write_text(json.dumps(self.previous))
                (directory / "SHA256SUMS").write_text("fixture")
                return ""
            shutil.copytree(self.candidate, directory)
            if self.signed:
                for name in driver.SIGNED: (directory / name).write_text("test signature")
            if self.changed_draft:
                (directory / "NOTICE").write_text("replaced")
            return ""
        if args[:3] == ("gh", "release", "view"):
            return json.dumps({"databaseId": 12, "tagName": "v0.12.0", "isDraft": not self.published,
                               "isPrerelease": not self.published,
                               "url": "https://github.com/houllette/lemieux/releases/tag/v0.12.0"})
        if args[:3] == ("gh", "attestation", "verify"):
            return ""
        if args[:3] == ("gh", "release", "edit"):
            self.published = True
            self.latest_override = None
            if self.fail_after == "github":
                self.fail_after = None; raise driver.ReleaseError("lost GitHub response")
            return ""
        raise AssertionError("Unexpected command: " + repr(args))


class ReleaseDriverTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="release tests with spaces ")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.world = World(self.base)
        self.state = self.base / "state"; self.state.mkdir()
        self.key = self.base / "unused placeholder.key"; self.key.write_text("not a real key")

    def release(self, **options):
        release = driver.Release(self.world.fixture, "0.12.0", self.key, self.state, runner=self.world,
                                 poll=0, wait=1, hex_get=lambda: copy.deepcopy(self.world.hex), **options)
        release.api = self.world.api
        return release

    def start(self, **options):
        with contextlib.redirect_stdout(io.StringIO()):
            self.release(**options).start()

    def checkpoint(self):
        return json.loads((self.state / "state.json").read_text())

    def test_complete_release_order_and_cleanup(self):
        self.start()
        state = self.checkpoint()
        self.assertEqual(state["phase"], "complete")
        self.assertNotIn("scratch", state)
        self.assertTrue(self.world.published and self.world.signed and self.world.hex["has_docs"])
        writes = [args for args in self.world.calls if args[:2] == ("git", "push") or
                  (len(args) > 4 and args[4] in ("lmx.release.sign_draft", "hex.publish") and "--dry-run" not in args) or
                  args[:3] == ("gh", "release", "edit")]
        self.assertEqual(["push" if a[0] == "git" else a[4] if a[0] == "mise" else "publish-github" for a in writes],
                         ["push", "lmx.release.sign_draft", "hex.publish", "publish-github"])
        self.assertTrue(list(self.state.glob("*.log")))
        self.assertIn(("git", "config", "user.email", "123+maintainer@users.noreply.github.com"), self.world.calls)
        scratch = next(Path(c[-1]).parent for c in self.world.calls if c[:2] == ("git", "clone"))
        self.assertFalse(scratch.exists())

    def test_verified_draft_resolves_unpublished_release_without_tag_rest_lookup(self):
        release = self.release()
        self.world.pushed = True
        release.state.update(source_sha=self.world.sha, inventory=release.snapshot(self.world.candidate))
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                result = release.verified_draft(self.base / "downloaded-draft",
                                               self.world.run("release.yml", "push", "v0.12.0", 4))
            self.assertTrue(result["draft"])
            self.assertTrue(result["prerelease"])
            self.assertFalse(self.world.published or self.world.signed)
        finally:
            release.log_file.close()

    def test_release_metadata_must_match_the_requested_tag(self):
        release = self.release()
        release.run = lambda *args, **kwargs: json.dumps({"databaseId": 12, "tagName": "v0.13.0",
                                                        "isDraft": True, "isPrerelease": True,
                                                        "url": "https://github.com/houllette/lemieux/releases/tag/v0.13.0"})
        try:
            with self.assertRaisesRegex(driver.ReleaseError, "invalid release identity"):
                release.release_info()
        finally:
            release.log_file.close()

    def accepted_write(self, boundary):
        self.world.fail_after = boundary
        with self.assertRaisesRegex(driver.ReleaseError, "lost"):
            self.start()
        retained = Path(self.checkpoint()["scratch"])
        self.assertTrue((retained / "source/.git").is_dir())
        self.assertFalse((retained / "source/erl_crash.dump").exists())
        self.assertFalse(any((retained / name).exists() for name in ("candidate", "rehearsal", "draft", "signed", "final")))
        self.start()
        self.assertFalse(retained.exists())
        self.assertEqual(self.checkpoint()["phase"], "complete")
        self.assertEqual(sum(c[:2] == ("git", "push") for c in self.world.calls), 1)
        self.assertEqual(sum(len(c) > 5 and c[4] == "hex.publish" and c[5] == "--yes" for c in self.world.calls), 1)
        self.assertEqual(sum(c[:2] == ("git", "clone") for c in self.world.calls), 1)
        self.assertEqual(sum(len(c) > 4 and c[4] == "deps.get" for c in self.world.calls), 2)
        self.assertEqual(sum(len(c) > 4 and c[4] == "lmx.release.sign_draft" for c in self.world.calls), 1)

    def test_resume_after_accepted_tag_push_with_lost_response(self):
        self.accepted_write("push")

    def test_resume_after_accepted_hex_upload_with_lost_response(self):
        self.accepted_write("hex")

    def test_resume_after_accepted_github_publication_with_lost_response(self):
        self.accepted_write("github")

    def test_resume_pushes_unpublished_local_tag_without_recreating_it(self):
        self.world.fail_after = "push-before"
        with self.assertRaisesRegex(driver.ReleaseError, "not accepted"): self.start()
        self.assertTrue(self.world.tagged)
        self.assertFalse(self.world.pushed)
        self.start()
        self.assertTrue(self.world.published)
        self.assertEqual(sum(c[:3] == ("git", "tag", "-a") for c in self.world.calls), 1)
        self.assertEqual(sum(c[:2] == ("git", "push") for c in self.world.calls), 2)

    def test_interrupted_bootstrap_retains_compiled_files_and_checkout(self):
        self.world.fail_after = "bootstrap"
        with self.assertRaisesRegex(driver.ReleaseError, "Interrupted"): self.start()
        cache = Path(self.checkpoint()["scratch"])
        self.assertTrue((cache / "source/dist/lmx/_build/retained-compile").is_file())
        self.assertNotIn("bootstrap_ready", self.checkpoint())
        self.start()
        self.assertFalse(cache.exists())
        self.assertEqual(sum(c[:2] == ("git", "clone") for c in self.world.calls), 1)

    def test_fresh_rebuilds_local_cache_without_resetting_remote_progress(self):
        self.world.fail_after = "hex"
        with self.assertRaises(driver.ReleaseError): self.start()
        cache = Path(self.checkpoint()["scratch"])
        self.start(fresh=True)
        self.assertFalse(cache.exists())
        self.assertEqual(sum(c[:2] == ("git", "clone") for c in self.world.calls), 2)
        self.assertEqual(sum(c[:2] == ("git", "push") for c in self.world.calls), 1)
        self.assertEqual(sum(len(c) > 5 and c[4:6] == ("hex.publish", "--yes") for c in self.world.calls), 1)

    def test_modified_retained_checkout_is_refused_before_resume(self):
        self.world.fail_after = "push"
        with self.assertRaises(driver.ReleaseError): self.start()
        original = self.world.__class__.__call__
        def dirty(world, args, **kwargs):
            if tuple(args)[:2] == ("git", "status"): return " M VERSION"
            return original(world, args, **kwargs)
        before = len(self.world.calls)
        with patch.object(World, "__call__", dirty):
            with self.assertRaisesRegex(driver.ReleaseError, "modified source"): self.start()
        self.assertFalse(any(len(c)>4 and c[4]=="run" for c in self.world.calls[before:]))

    def test_retained_checkout_symlink_cannot_redirect_resume(self):
        self.world.fail_after = "push"
        with self.assertRaises(driver.ReleaseError): self.start()
        source = Path(self.checkpoint()["scratch"]) / "source"
        shutil.rmtree(source); source.symlink_to(self.world.fixture, target_is_directory=True)
        before = (self.world.fixture / "VERSION").read_bytes()
        with self.assertRaisesRegex(driver.ReleaseError, "symlink"): self.start()
        self.assertEqual((self.world.fixture / "VERSION").read_bytes(), before)

    def test_completed_release_rerun_does_not_publish_again(self):
        self.start(); before = len(self.world.calls)
        self.start()
        later = self.world.calls[before:]
        self.assertFalse(any(c[:2] == ("git", "push") or c[:3] == ("gh", "release", "edit") for c in later))
        self.assertFalse(any(len(c) > 4 and c[4] == "lmx.release.sign_draft" for c in later))
        self.assertFalse(any(len(c) > 5 and c[4] == "hex.publish" and "--dry-run" not in c for c in later))
        self.assertFalse(any(c[:3] == ("gh", "run", "download") for c in later))

    def test_resume_repairs_published_release_latest_without_republishing_hex(self):
        self.start()
        self.world.latest_override = "v0.11.0"
        before = len(self.world.calls)
        self.start()
        later = self.world.calls[before:]
        self.assertEqual(sum(c[:3] == ("gh", "release", "edit") for c in later), 1)
        self.assertFalse(any(len(c) > 5 and c[4:6] == ("hex.publish", "--yes") for c in later))
        self.assertEqual(self.world.api("repos/houllette/lemieux/releases/latest")["tag_name"], "v0.12.0")

    def test_draft_replacement_after_hex_never_publishes_github(self):
        self.world.fail_after = "replace"
        with self.assertRaisesRegex(driver.ReleaseError, "Checksum mismatch"):
            self.start()
        self.assertIsNotNone(self.world.hex)
        self.assertFalse(self.world.published)
        self.assertEqual(self.checkpoint()["phase"], "stopped")

    def test_workflow_rerun_after_hex_never_publishes_stale_candidate(self):
        self.world.fail_after = "attempt"
        with self.assertRaisesRegex(driver.ReleaseError, "workflow changed"):
            self.start()
        self.assertIsNotNone(self.world.hex)
        self.assertFalse(self.world.published)

    def test_resume_uploads_only_docs_when_hex_package_already_exists(self):
        self.world.fail_after = "hex"
        with self.assertRaises(driver.ReleaseError): self.start()
        self.world.hex["has_docs"] = False
        self.start()
        normal = [c for c in self.world.calls if len(c) > 5 and c[4:6] == ("hex.publish", "--yes")]
        docs = [c for c in self.world.calls if len(c) > 6 and c[4:7] == ("hex.publish", "docs", "--yes")]
        self.assertEqual(len(normal), 1)
        self.assertEqual(len(docs), 1)
        self.assertEqual(sum(len(c)>5 and c[4:6]==("hex.publish", "--dry-run") for c in self.world.calls), 1)
        self.assertEqual(sum(len(c)>4 and c[4]=="hex.build" for c in self.world.calls), 1)
        self.assertTrue(self.world.published)

    def test_existing_foreign_hex_version_is_not_overwritten(self):
        self.world.hex = {"checksum": "9" * 64, "has_docs": True}
        with self.assertRaisesRegex(driver.ReleaseError, "refusing overwrite"):
            self.start()
        self.assertFalse(self.world.published)
        self.assertFalse(any("--replace" in c for c in self.world.calls))

    def test_candidate_corruption_stops_before_signing(self):
        (self.world.candidate / "lmx_linux.tar.gz").write_bytes(b"bad")
        with self.assertRaisesRegex(driver.ReleaseError, "Checksum mismatch"):
            self.start()
        self.assertFalse(self.world.signed or self.world.published or self.world.pushed)

    def test_validly_checksummed_report_with_wrong_predecessor_is_refused(self):
        path = self.world.candidate / "upgrade-report-linux.json"
        report = json.loads(path.read_text()); report["previous_sha256"] = "8" * 64
        path.write_text(json.dumps(report)); self.world.sums()
        with self.assertRaisesRegex(driver.ReleaseError, "Qualification mismatch"):
            self.start()
        self.assertFalse(self.world.signed)

    def test_api_normalizes_http_headers_and_never_treats_auth_failure_as_absence(self):
        release = self.release()
        release.api = driver.Release.api.__get__(release)
        release.run = lambda *args, **kwargs: 'HTTP/2.0 200 OK\r\ncontent-type: application/json\r\n\r\n{"ok":true}\n'
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(release.api("endpoint"), {"ok": True})
                release.run = lambda *args, **kwargs: (_ for _ in ()).throw(driver.ReleaseError("HTTP/2.0 403 Forbidden"))
                with self.assertRaisesRegex(driver.ReleaseError, "403"):
                    release.api("endpoint", absent=True)
        finally:
            release.log_file.close()

    def test_failed_workflow_stops_by_default_and_explicit_retry_is_bounded(self):
        release = self.release()
        run = self.world.run("release.yml", "push", "v0.12.0", 4)
        run["conclusion"] = "failure"
        release.runs = lambda *args: [copy.deepcopy(run)]
        release.api = lambda *args, **kwargs: copy.deepcopy(run)
        writes = []
        def rerun(args, **kwargs):
            writes.append(tuple(args))
            run["run_attempt"] += 1
            return ""
        release.run = rerun
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(driver.ReleaseError, "Workflow failed"):
                    release.await_run("release.yml", "push", self.world.sha, "v0.12.0")
                self.assertEqual(writes, [])
                release.retry_failed = True
                with self.assertRaisesRegex(driver.ReleaseError, "Workflow failed"):
                    release.await_run("release.yml", "push", self.world.sha, "v0.12.0")
            self.assertEqual(writes, [("gh", "run", "rerun", "4", "--repo", driver.REPO, "--failed")])
            self.assertEqual(run["run_attempt"], 2)
        finally:
            release.log_file.close()

    def test_checkpointed_source_can_resume_after_main_advances(self):
        self.world.fail_after = "push"
        with self.assertRaises(driver.ReleaseError): self.start()
        self.world.tagged = False
        original = self.world.__class__.__call__
        def advanced(world, args, **kwargs):
            if tuple(args) == ("git", "rev-parse", "origin/main^{commit}"): return "c" * 40
            return original(world, args, **kwargs)
        with patch.object(World, "__call__", advanced):
            self.start()
        self.assertEqual(self.checkpoint()["source_sha"], self.world.sha)

    def test_key_symlink_into_checkout_is_refused(self):
        (self.world.fixture / ".git").mkdir()
        tracked_key = self.world.fixture / "key"; tracked_key.write_text("placeholder")
        alias = self.base / "key-alias"; alias.symlink_to(tracked_key)
        with self.assertRaisesRegex(driver.ReleaseError, "outside every Git"):
            driver.validate_key_path(alias)

    def test_lock_prevents_overlapping_releases_and_releases_on_exit(self):
        path = self.state / "release.lock"
        with driver.release_lock(path):
            with self.assertRaisesRegex(driver.ReleaseError, "Another local release"):
                with driver.release_lock(path): self.fail("must not acquire twice")
        with driver.release_lock(path): self.assertTrue(path.exists())

    def test_resume_reclaims_reserved_directory_after_kill_before_marker(self):
        owner = {"repo": driver.REPO, "version": "0.12.0", "id": uuid.uuid4().hex}
        scratch = Path(tempfile.gettempdir()).resolve() / ("lemieux-release-" + owner["id"])
        scratch.mkdir(mode=0o700)
        self.addCleanup(lambda: shutil.rmtree(scratch, ignore_errors=True))
        (scratch / "partial-download").write_text("interrupted")
        state = {"schema_version": 1, "repo": driver.REPO, "version": "0.12.0",
                 "scratch": str(scratch), "scratch_owner": owner}
        driver.atomic_json(self.state / "state.json", state)
        self.start()
        self.assertFalse(scratch.exists())
        self.assertEqual(self.checkpoint()["phase"], "complete")

    def test_runner_times_out_and_redacts_inherited_tokens(self):
        lines = []
        with patch.dict(os.environ, HEX_API_KEY="throwaway-test-token"):
            runner = driver.Runner(lines.append, 10, self.key)
            clock = time.monotonic
            with patch.object(driver.time, "monotonic", side_effect=lambda: clock() + (120 if "<redacted>" in lines else 0)):
                with self.assertRaisesRegex(driver.ReleaseError, "timed out"):
                    runner([sys.executable, "-c", "import os,time; print(os.environ['HEX_API_KEY'],flush=True); time.sleep(60)"], self.base)
        self.assertIn("<redacted>", "\n".join(lines))
        self.assertNotIn("throwaway-test-token", "\n".join(lines))

    def test_timeout_kills_grandchild_after_its_parent_exits(self):
        lines = []
        runner = driver.Runner(lines.append, 10, self.key)
        child_code = "import os,time\nwhile os.getppid()==PARENT: time.sleep(0.01)\nprint('CHILD='+str(os.getpid()),flush=True)\ntime.sleep(60)"
        code = "import os,subprocess,sys; subprocess.Popen([sys.executable,'-c'," + repr(child_code) + ".replace('PARENT',str(os.getpid()))])"
        clock = time.monotonic
        with patch.object(driver.time, "monotonic", side_effect=lambda: clock() + (120 if any(line.startswith("CHILD=") for line in lines) else 0)):
            with self.assertRaisesRegex(driver.ReleaseError, "timed out"):
                runner([sys.executable, "-c", code], self.base)
        child = next(line.split("=", 1)[1] for line in lines if line.startswith("CHILD="))
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            result = subprocess.run(["ps", "-p", child, "-o", "stat="], capture_output=True, text=True)
            if result.returncode != 0 or result.stdout.strip().startswith("Z"):
                break
            time.sleep(0.05)
        self.assertTrue(result.returncode != 0 or result.stdout.strip().startswith("Z"), result.stdout)

    def test_shell_entrypoint_handles_checkout_paths_with_spaces(self):
        scripts = self.base / "checkout with spaces/scripts"; scripts.mkdir(parents=True)
        for name in ("release.sh", "release.py", "release_checksums.py"):
            shutil.copy2(ROOT / "scripts" / name, scripts / name)
        result = subprocess.run(["sh", str(scripts / "release.sh"), "--help"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("version key", result.stdout)


if __name__ == "__main__":
    unittest.main()
