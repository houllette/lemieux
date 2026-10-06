"""Check release completeness and fail-closed installation without executing a binary."""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest
import importlib.util
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("lmx_installer", ROOT / "scripts/install.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class ReleaseToolsTest(unittest.TestCase):
    def test_incomplete_candidate_cannot_produce_checksums(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(ROOT / "scripts/release_checksums.py"), directory],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Missing or empty", result.stderr)
            self.assertFalse((Path(directory) / "SHA256SUMS").exists())

    def archive(self, root, target, version="0.1.0", unsafe=None, modes=None):
        archive = root / f"lmx_{target}.tar.gz"
        info = {"version": version, "target": target, "build_id": "a" * 64}
        files = {"bin/lmx": b"#!/bin/sh\nexit 99\n",
                 f"releases/{version}/release.json": json.dumps(info).encode(),
                 f"releases/{version}/lmx.rel": b"release"}
        if unsafe:
            files[unsafe] = b"escape"
        for name in modes or {}:
            files.setdefault(name, b"packaged file")
        with tarfile.open(archive, "w:gz") as bundle:
            for name, data in files.items():
                item = tarfile.TarInfo(name)
                item.size = len(data)
                item.mode = (modes or {}).get(name, 0o755 if name == "bin/lmx" else 0o644)
                bundle.addfile(item, io.BytesIO(data))
        sums = root / "SHA256SUMS"
        sums.write_text(f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}\n")
        return archive, sums

    def test_installer_verifies_integrity_and_switches_full_version_directories(self):
        target = {("Darwin", "arm64"): "macos_silicon", ("Darwin", "x86_64"): "macos",
                  ("Linux", "x86_64"): "linux"}.get((platform.system(), platform.machine().lower()))
        if target is None:
            self.skipTest("Unix installer only")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive, sums = self.archive(root, target)
            command = [sys.executable, str(ROOT / "scripts/install.py"), str(archive),
                       "--checksums", str(sums), "--prefix", str(root / "install")]
            good = sums.read_text()
            sums.write_text(f"{'0' * 64}  {archive.name}\n")
            failed = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(failed.returncode, 0)
            self.assertFalse((root / "install").exists())
            sums.write_text(good)
            installed = subprocess.run(command, check=True, capture_output=True, text=True)
            # Through install.sh, install.py was itself downloaded and run, so
            # the closing line claims only what is true: the archive never ran.
            self.assertIn("Nothing from the archive was executed.", installed.stdout)
            self.assertNotIn("Nothing downloaded was executed", installed.stdout)
            current = root / "install/share/lmx/current"
            old = current.resolve()
            self.assertEqual((old / "bin/lmx").read_bytes(), b"#!/bin/sh\nexit 99\n")
            launcher = root / "install/bin/lmx"
            self.assertTrue(launcher.is_file())
            # Running the installer again upgrades its own installation without
            # --replace (issue #5): the launcher it wrote is how it knows.
            self.archive(root, target, "0.1.1")
            subprocess.run(command, check=True, capture_output=True)
            self.assertNotEqual(old, current.resolve())
            self.assertTrue(old.is_dir())
            # A launcher it did not write — another program, or its own wrapper
            # for another prefix — is left alone until --replace says otherwise.
            for foreign in (b"#!/bin/sh\necho someone else's lmx\n",
                            installer.wrapper(Path("/elsewhere/share/lmx")).encode()):
                launcher.write_bytes(foreign)
                refused = subprocess.run(command, capture_output=True, text=True)
                self.assertNotEqual(refused.returncode, 0)
                self.assertIn("--replace", refused.stderr)
                self.assertEqual(launcher.read_bytes(), foreign)
            subprocess.run(command + ["--replace"], check=True, capture_output=True)
            # The installer resolves the prefix (macOS keeps /var under /private).
            self.assertEqual(launcher.read_text(), installer.wrapper((root / "install").resolve() / "share/lmx"))

    def test_complete_candidate_manifest_binds_every_target_to_its_archive(self):
        import io
        import json
        import tarfile
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for target in ("linux", "macos", "macos_silicon", "windows"):
                # Every key Lmx.Release writes into release.json.
                info = {"version": "0.1.0", "target": target, "build_id": "a" * 64,
                        "native_id": "b" * 64, "dependency_id": "d" * 64, "config_id": "e" * 64,
                        "erts": "17", "elixir": "1.20.2", "dependencies": {"ex_ratatui": "0.16.0"},
                        "hot_modules": [], "upgrade_from": []}
                body = json.dumps(info).encode()
                with tarfile.open(root / f"lmx_{target}.tar.gz", "w:gz") as archive:
                    entry = tarfile.TarInfo("releases/0.1.0/release.json")
                    entry.size = len(body)
                    archive.addfile(entry, io.BytesIO(body))
            for name in ("LICENSE", "NOTICE", "release-notes.md", "install.py", "install.sh", "upgrade-plan.exs"):
                (root / name).write_text("fixture")
            written = subprocess.run([sys.executable, str(ROOT / "scripts/release_checksums.py"), str(root)],
                                     check=True, capture_output=True, text=True)
            # The key is offline: the script signs nothing, and names what is left
            # to sign and which consumer needs each signature.
            self.assertIn("SHA256SUMS.sig and update.json.sig", written.stdout)
            self.assertIn("Installed lmx installs nothing without update.json.sig", written.stdout)
            self.assertIn("install.py installs nothing without SHA256SUMS.sig", written.stdout)
            self.assertIn("mix lmx.release.sign_draft --tag v0.1.0", written.stdout)
            self.assertEqual(sorted(path.name for path in root.glob("*.sig")), [])
            manifest = json.loads((root / "update.json").read_text())
            self.assertEqual(manifest["version"], "0.1.0")
            self.assertEqual(len(manifest["targets"]), 4)
            for target, info in manifest["targets"].items():
                self.assertEqual(info["target"], target)
                self.assertEqual(info["sha256"], hashlib.sha256((root / f"lmx_{target}.tar.gz").read_bytes()).hexdigest())
            # A declared hot path must have evidence for these exact archive
            # and plan bytes; the synthetic fixture cannot stand in for it.
            target = "macos_silicon"
            info = dict(manifest["targets"][target])
            info.pop("sha256")
            info["upgrade_from"] = [{"version": "0.0.9", "build_id": "c" * 64}]
            body = json.dumps(info).encode()
            with tarfile.open(root / f"lmx_{target}.tar.gz", "w:gz") as archive:
                entry = tarfile.TarInfo("releases/0.1.0/release.json")
                entry.size = len(body)
                archive.addfile(entry, io.BytesIO(body))
            failed = subprocess.run([sys.executable, str(ROOT / "scripts/release_checksums.py"), str(root)], capture_output=True, text=True)
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("Missing actual artifact qualification", failed.stderr)
            digest = hashlib.sha256((root / f"lmx_{target}.tar.gz").read_bytes()).hexdigest()
            qualified_to = dict(info, sha256=digest)
            report = {"to": qualified_to, "target": target, "from": {"version": "0.0.9", "build_id": "c" * 64},
                      "candidate_sha256": digest, "plan_sha256": hashlib.sha256((root / "upgrade-plan.exs").read_bytes()).hexdigest(),
                      "tools_and_transcript_resume": True, "cold_boot": True, "restart_install": True,
                      "live_hot_upgrade": True, "live_downgrade": False,
                      "live_session_survived": True, "unsent_draft_preserved": True,
                      "interrupted_preparation_fallback": True, "failed_health_rolled_back": True,
                      "failed_build_quarantined": True}
            (root / f"upgrade-report-{target}.json").write_text(json.dumps(report))
            failed = subprocess.run([sys.executable, str(ROOT / "scripts/release_checksums.py"), str(root)], capture_output=True, text=True)
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("upgrade/downgrade qualification", failed.stderr)
            report["live_downgrade"] = True
            (root / f"upgrade-report-{target}.json").write_text(json.dumps(report))
            subprocess.run([sys.executable, str(ROOT / "scripts/release_checksums.py"), str(root)], check=True, capture_output=True)
            report["plan_sha256"] = "0" * 64
            (root / f"upgrade-report-{target}.json").write_text(json.dumps(report))
            failed = subprocess.run([sys.executable, str(ROOT / "scripts/release_checksums.py"), str(root)], capture_output=True, text=True)
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("does not match candidate/plan", failed.stderr)

    def test_manifest_entries_the_updater_would_reject_are_refused(self):
        # Lmx.Update.select/2 refuses an entry missing any identity field, an
        # unstable version, or a predecessor that is not an older stable
        # version with a build digest (predecessors?/2). Such a manifest would
        # be signed, published and then refused by every installed lmx, so
        # the candidate script refuses it first.
        import io
        import json
        import tarfile
        def predecessor(version, build_id):
            return lambda info: info.update(upgrade_from=[{"version": version, "build_id": build_id}])
        cases = (("config_id", "0.1.0", lambda info: info.pop("config_id")),
                 ("hot_modules", "0.1.0", lambda info: info.pop("hot_modules")),
                 ("not a stable X.Y.Z version", "0.1.0-rc1", None),
                 ("upgrade_from entry", "0.1.0", predecessor("0.1.0", "c" * 64)),
                 ("upgrade_from entry", "0.1.0", predecessor("0.2.0", "c" * 64)),
                 ("upgrade_from entry", "0.1.0", predecessor("0.0.9-rc1", "c" * 64)),
                 ("upgrade_from entry", "0.1.0", predecessor("0.0.9", "not a digest")),
                 ("upgrade_from entry", "0.1.0", lambda info: info.update(upgrade_from=["0.0.9"])))
        for expected, version, edit in cases:
            with self.subTest(expected=expected, version=version), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                for target in ("linux", "macos", "macos_silicon", "windows"):
                    info = {"version": version, "target": target, "build_id": "a" * 64,
                            "native_id": "b" * 64, "dependency_id": "d" * 64, "config_id": "e" * 64,
                            "erts": "17", "elixir": "1.20.2", "dependencies": {}, "hot_modules": [],
                            "upgrade_from": []}
                    if target == "linux" and edit:
                        edit(info)
                    body = json.dumps(info).encode()
                    with tarfile.open(root / f"lmx_{target}.tar.gz", "w:gz") as archive:
                        entry = tarfile.TarInfo(f"releases/{version}/release.json")
                        entry.size = len(body)
                        archive.addfile(entry, io.BytesIO(body))
                for name in ("LICENSE", "NOTICE", "release-notes.md", "install.py", "install.sh", "upgrade-plan.exs"):
                    (root / name).write_text("fixture")
                result = subprocess.run([sys.executable, str(ROOT / "scripts/release_checksums.py"), str(root)],
                                        capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)
                self.assertIn("updater", result.stderr)
                self.assertFalse((root / "update.json").exists())
                self.assertFalse((root / "SHA256SUMS").exists())

    def test_installer_rejects_traversal_before_pointer_changes(self):
        target = {("Darwin", "arm64"): "macos_silicon", ("Darwin", "x86_64"): "macos",
                  ("Linux", "x86_64"): "linux"}.get((platform.system(), platform.machine().lower()))
        if target is None:
            self.skipTest("Unix installer only")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive, sums = self.archive(root, target, unsafe="../../outside")
            result = subprocess.run([sys.executable, str(ROOT / "scripts/install.py"), str(archive),
                                     "--checksums", str(sums), "--prefix", str(root / "install")],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unsafe release archive", result.stderr)
            self.assertFalse((root / "outside").exists())
            self.assertFalse((root / "install/share/lmx/current").exists())

    def test_interrupted_installs_are_retryable_and_launcher_failure_restores_pointer(self):
        target = installer.TARGETS.get((platform.system(), platform.machine().lower()))
        if target is None:
            self.skipTest("Unix installer only")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive, sums = self.archive(root, target)
            prefix = root / "install"
            launcher = installer.install(archive, sums, prefix)
            current = prefix / "share/lmx/current"
            old = current.resolve()
            self.assertEqual(installer.install(archive, sums, prefix, replace=True), launcher)
            self.archive(root, target, "0.1.1")
            real_replace = installer.os.replace
            def fail_launcher(source, destination):
                if Path(destination) == launcher:
                    raise OSError("simulated launcher publication failure")
                return real_replace(source, destination)
            with patch.object(installer.os, "replace", side_effect=fail_launcher):
                with self.assertRaisesRegex(OSError, "publication failure"):
                    installer.install(archive, sums, prefix, replace=True)
            self.assertEqual(current.resolve(), old)
            self.assertEqual(launcher.read_text().count("current/bin/lmx"), 1)
            installer.install(archive, sums, prefix, replace=True)
            self.assertNotEqual(current.resolve(), old)
            (current.resolve() / ".unexpected").write_text("unverified extra file")
            with self.assertRaisesRegex(ValueError, "differs"):
                installer.install(archive, sums, prefix, replace=True)

    def test_stale_locks_recover_but_live_locks_are_preserved(self):
        import os
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            lock = home / ".update-lock"
            dead = subprocess.Popen([sys.executable, "-c", "pass"])
            dead.wait()
            lock.write_text(str(dead.pid))
            with installer.lock(home):
                self.assertEqual(lock.read_text(), str(os.getpid()))
            self.assertFalse(lock.exists())
            lock.write_text(str(os.getpid()))
            with self.assertRaisesRegex(ValueError, "installation is busy: an lmx update or another install"):
                with installer.lock(home, wait=0.3):
                    self.fail("live lock must not be stolen")
            self.assertEqual(lock.read_text(), str(os.getpid()))

    def test_a_held_lock_is_waited_for_and_then_taken(self):
        # A terminal UI holds the lock while it stages an automatic update;
        # the installer used to fail at once with "[Errno 17] File exists".
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            lock = home / ".update-lock"
            lock.write_text(str(os.getpid()))
            release = threading.Timer(1.5, lock.unlink)
            release.start()
            stderr = io.StringIO()
            try:
                with contextlib.redirect_stderr(stderr), installer.lock(home, wait=10):
                    self.assertEqual(lock.read_text(), str(os.getpid()))
            finally:
                release.cancel()
            self.assertIn("waiting up to 10 seconds", stderr.getvalue())
            self.assertFalse(lock.exists())

    def test_a_busy_installation_is_reported_in_words(self):
        target = installer.TARGETS.get((platform.system(), platform.machine().lower()))
        if target is None:
            self.skipTest("Unix installer only")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive, sums = self.archive(root, target)
            home = root / "install/share/lmx"
            home.mkdir(parents=True)
            (home / ".update-lock").write_text(str(os.getpid()))
            stderr = io.StringIO()
            with patch.object(installer, "LOCK_WAIT", 0.2), contextlib.redirect_stderr(stderr), \
                    self.assertRaises(SystemExit) as exit:
                installer.main([str(archive), "--checksums", str(sums), "--prefix", str(root / "install")])
            self.assertEqual(exit.exception.code, 2)
            self.assertIn(": error: installation is busy", stderr.getvalue())
            self.assertIn("docs/support.md", stderr.getvalue())
            self.assertNotIn("Errno", stderr.getvalue())
            self.assertFalse((home / "current").exists())

    def test_launcher_registers_before_boot_and_preserves_argument_bytes(self):
        import os
        import shutil
        import time
        if os.name == "nt":
            self.skipTest("Unix launch protocol")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "bin").mkdir()
            home = root / "home"
            home.mkdir()
            shutil.copy2(ROOT / "dist/lmx/priv/launcher.sh", root / "bin/lmx")
            (root / "bin/lmx").chmod(0o755)
            release = root / "bin/lmx-release"
            release.write_text('#!/bin/sh\nset -eu\ncat "$LMX_LEASE_FILE" > "$LMX_INSTALL_HOME/booted"\ncp "$LMX_ARGV_FILE" "$LMX_INSTALL_HOME/args"\n')
            release.chmod(0o755)
            lock = home / ".update-lock"
            lock.write_text(str(os.getpid()))
            env = dict(os.environ, LMX_INSTALL_HOME=str(home))
            process = subprocess.Popen([str(root / "bin/lmx"), "two lines\nsecond", "$(never execute)", ""], env=env)
            try:
                time.sleep(0.15)
                self.assertIsNone(process.poll())
                self.assertFalse((home / "booted").exists())
                lock.unlink()
                self.assertEqual(process.wait(timeout=5), 0)
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
            self.assertEqual((home / "booted").read_text(), str(process.pid))
            self.assertEqual((home / "args").read_bytes(), b"two lines\nsecond\0$(never execute)\0\0")
            self.assertEqual(list((home / "running").iterdir()), [])

    def test_launcher_passes_standard_input_to_the_release(self):
        # POSIX gives an asynchronous command in a non-interactive shell
        # /dev/null as standard input unless the command redirects it itself.
        # The launcher backgrounds the VM to forward signals, so without an
        # explicit redirection every prompt or answer piped to `lmx` vanished.
        import os
        import shutil
        if os.name == "nt":
            self.skipTest("Unix launch protocol")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "bin").mkdir()
            shutil.copy2(ROOT / "dist/lmx/priv/launcher.sh", root / "bin/lmx")
            (root / "bin/lmx").chmod(0o755)
            captured = root / "stdin"
            release = root / "bin/lmx-release"
            release.write_text(f'#!/bin/sh\nset -eu\ncat > "{captured}"\n')
            release.chmod(0o755)
            env = {key: value for key, value in os.environ.items() if key != "LMX_INSTALL_HOME"}
            # Through the launcher's own `#!/bin/sh`, and through dash as well
            # where it exists: dash (Ubuntu's /bin/sh) is the shell whose POSIX
            # /dev/null rule defeated `<&0`, and macOS's /bin/sh is not dash.
            launches = [[str(root / "bin/lmx")]]
            if shutil.which("dash"):
                launches.append([shutil.which("dash"), str(root / "bin/lmx")])
            for launch in launches:
                with self.subTest(launch=launch[0]):
                    captured.unlink(missing_ok=True)
                    result = subprocess.run(launch + ["run", "-"], env=env,
                                            input=b"summarize this\nsecond line\n",
                                            capture_output=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(captured.read_bytes(), b"summarize this\nsecond line\n")

    # Files as release archives carry them, among them a Hex package's 0664
    # grammar, which Python's "data" filter extracts as 0644 and :erl_tar as
    # 0664.
    MODES = {"lib/jsv-0.21.2/priv/grammars/email-address.abnf": 0o664, "bin/lmx-release": 0o755,
             "releases/0.1.0/lmx.rel": 0o444, "lib/app-1.0/priv/odd": 0o654, "LICENSE": 0o644}

    def extract_exactly(self, archive, destination):
        """Extracts keeping every mode, as the updater's :erl_tar does; with erl_tar itself where erl is on PATH."""
        destination.mkdir()
        erl = shutil.which("erl")
        if erl:
            subprocess.run([erl, "-noshell", "-eval",
                            f'ok = erl_tar:extract("{archive}", [compressed, {{cwd, "{destination}"}}]), halt().'],
                           check=True, capture_output=True, timeout=120)
        else:
            with tarfile.open(archive) as bundle:
                options = {"filter": "fully_trusted"} if hasattr(tarfile, "fully_trusted_filter") else {}
                bundle.extractall(destination, **options)

    def test_install_py_and_the_updater_extract_one_archive_to_the_same_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive, _ = self.archive(root, "linux", modes=self.MODES)
            filtered = root / "install.py"
            filtered.mkdir()
            installer.extract(archive, filtered)
            exact = root / "updater"
            self.extract_exactly(archive, exact)
            grammar = "lib/jsv-0.21.2/priv/grammars/email-address.abnf"
            self.assertEqual((exact / grammar).stat().st_mode & 0o777, 0o664)
            if hasattr(tarfile, "data_filter"):
                # The filter really did change it: this is the case that was refused.
                self.assertEqual((filtered / grammar).stat().st_mode & 0o777, 0o644)
            self.assertEqual(installer.payload(exact), installer.payload(filtered))
            # Execute permission is still verified.
            (exact / grammar).chmod(0o755)
            self.assertNotEqual(installer.payload(exact), installer.payload(filtered))

    def test_canonical_mode_is_what_the_data_filter_leaves(self):
        if not hasattr(tarfile, "data_filter"):
            self.skipTest("this Python has no tarfile data filter")
        with tempfile.TemporaryDirectory() as directory:
            for mode in range(0o10000):
                member = tarfile.TarInfo("file")
                member.mode = mode
                self.assertEqual(installer.canonical_mode(mode), tarfile.data_filter(member, directory).mode,
                                 f"mode {mode:04o}")

    def test_an_existing_version_directory_the_updater_made_is_reused(self):
        target = installer.TARGETS.get((platform.system(), platform.machine().lower()))
        if target is None:
            self.skipTest("Unix installer only")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive, sums = self.archive(root, target, modes=self.MODES)
            prefix = root / "install"
            staged = prefix / "share/lmx/versions" / f"0.1.0-{'a' * 12}"
            staged.parent.mkdir(parents=True)
            self.extract_exactly(archive, staged)
            launcher = installer.install(archive, sums, prefix)
            self.assertEqual((prefix / "share/lmx/current").resolve(), staged.resolve())
            self.assertEqual(launcher.resolve(), (prefix / "bin/lmx").resolve())

    def test_a_unix_archive_with_modes_extractors_disagree_on_is_refused(self):
        def candidate(root, grammar_modes):
            for target in ("linux", "macos", "macos_silicon", "windows"):
                info = {"version": "0.1.0", "target": target, "build_id": "a" * 64,
                        "native_id": "b" * 64, "dependency_id": "d" * 64, "config_id": "e" * 64,
                        "erts": "17", "elixir": "1.20.2", "dependencies": {}, "hot_modules": [],
                        "upgrade_from": []}
                body = json.dumps(info).encode()
                files = {"releases/0.1.0/release.json": (body, 0o644),
                         "lib/jsv-0.21.2/priv/grammars/email-address.abnf": (b"grammar", grammar_modes[target])}
                with tarfile.open(root / f"lmx_{target}.tar.gz", "w:gz") as archive:
                    for name, (data, mode) in files.items():
                        entry = tarfile.TarInfo(name)
                        entry.size = len(data)
                        entry.mode = mode
                        archive.addfile(entry, io.BytesIO(data))
            return subprocess.run([sys.executable, str(ROOT / "scripts/release_checksums.py"), str(root)],
                                  capture_output=True, text=True)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("LICENSE", "NOTICE", "release-notes.md", "install.py", "install.sh", "upgrade-plan.exs"):
                (root / name).write_text("fixture")
            # Erlang on Windows reports every writable file as 0666, and
            # nothing extracts that archive into a version directory.
            modes = {"linux": 0o644, "macos": 0o644, "macos_silicon": 0o644, "windows": 0o666}
            written = candidate(root, modes)
            self.assertEqual(written.returncode, 0, written.stderr)
            (root / "SHA256SUMS").unlink()
            failed = candidate(root, dict(modes, linux=0o664))
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("lmx_linux.tar.gz has modes install.py and lmx's updater would extract differently",
                          failed.stderr)
            self.assertIn("lib/jsv-0.21.2/priv/grammars/email-address.abnf (0664)", failed.stderr)
            self.assertFalse((root / "SHA256SUMS").exists())

    def test_release_versions_and_ambiguous_archive_paths_are_rejected(self):
        for version in ("", ".", "..", "1", "01.2.3", "1.2.3-rc1", "1.2.3+preview"):
            self.assertFalse(installer.stable_version(version))
        self.assertTrue(installer.stable_version("1.2.3"))
        target = installer.TARGETS.get((platform.system(), platform.machine().lower()))
        if target is None:
            self.skipTest("Unix installer only")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for path in ("bin//lmx", "bin/lmx/child"):
                archive, _ = self.archive(root, target, unsafe=path)
                with self.assertRaisesRegex(ValueError, "unsafe"):
                    installer.extract(archive, root / "unpacked")


if __name__ == "__main__":
    unittest.main()
