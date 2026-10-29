"""Maintainer release transaction. See RELEASING.md for the public contract.

Checkpoints retain qualified artifact hashes, never permission to skip remote validation. A
process can die after a successful push/upload but before recording success;
every invocation reconciles tags, workflow attempts, draft bytes and Hex's
package checksum. Only read requests are retried automatically. Private-key
contents are handled exclusively by the existing local Mix signing helpers.
"""
import argparse
import contextlib
import datetime
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import selectors
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
import uuid

import release_checksums

REPO = "houllette/lemieux"
ROOT = Path(__file__).resolve().parents[1]
STABLE = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
TARGETS = release_checksums.TARGETS
SIGNED = {"SHA256SUMS.sig", "update.json.sig"}
KEY_CHECK = """
alias Lmx.Update.{Signing, Signature}
with {:ok, seed} <- Signing.read_private_key(System.fetch_env!("LMX_RELEASE_KEY_PATH")),
     {:ok, {:ok, pinned}} <- Signing.read_pinned("release-signing.pub"),
     true <- Signature.public_key(seed) == pinned do
  IO.puts("Release key matches the committed public key")
else
  _ -> Mix.raise("Release key is invalid or does not match release-signing.pub")
end
""".strip()


class ReleaseError(Exception):
    """An actionable failure, without a traceback or secret-bearing environment."""


def require(condition, message):
    if not condition:
        raise ReleaseError(message)


def sha256(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def atomic_json(path, value):
    temporary = path.with_suffix(".tmp")
    with temporary.open("w") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    descriptor = os.open(str(path.parent), os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def origin_repo(url):
    match = re.fullmatch(r"(?:git@github\.com:|https://github\.com/)([\w.-]+/[\w.-]+?)(?:\.git)?", url)
    require(match is not None, "origin must use a GitHub SSH or HTTPS URL without embedded credentials")
    return match.group(1)


def validate_key_path(path):
    path = Path(os.path.abspath(Path(path).expanduser()))
    require(path.is_file() and os.access(path, os.R_OK), "Release key must be a readable regular file")
    # Check both the spelling and its symlink destination. The Mix helper
    # refuses lexical checkout paths; resolving here closes the symlink case.
    for candidate in (path, path.resolve()):
        require(not any((parent / ".git").exists() for parent in candidate.parents),
                "Keep the release key outside every Git checkout (including symlink destinations)")
    return path.resolve()


class Runner:
    def __init__(self, log, timeout, key):
        self.log, self.timeout = log, timeout
        self.env = dict(os.environ, MIX_ENV="dev", LMX_CHECK_UPDATES="0", LMX_CONFIG="none",
                        HEX_API_URL="https://hex.pm/api")
        for name in ("MIX_BUILD_PATH", "MIX_DEPS_PATH", "MIX_APP_PATH", "LEMIEUX_DOCS_REF"):
            self.env.pop(name, None)
        self.env["LMX_RELEASE_KEY_PATH"] = str(key)
        self.redactions = [str(key)] + [value for name, value in self.env.items()
                                       if re.search(r"TOKEN|PASSWORD|SECRET|API_KEY", name) and len(value) >= 8]

    def clean(self, text):
        for secret in self.redactions:
            text = text.replace(secret, "<redacted>")
        return text

    def __call__(self, args, cwd, capture=False):
        args = [str(arg) for arg in args]
        self.log("$ " + self.clean(shlex.join(args)))
        output = bytearray()
        with subprocess.Popen(args, cwd=cwd, env=self.env, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              start_new_session=True) as process:
            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ)
            deadline, heartbeat, pending = time.monotonic() + self.timeout, time.monotonic(), b""
            finished = False
            try:
                while selector.get_map():
                    require(time.monotonic() < deadline, "Command timed out; rerun the same release command to resume")
                    for key, _ in selector.select(timeout=1):
                        chunk = os.read(key.fileobj.fileno(), 65536)
                        if not chunk:
                            selector.unregister(key.fileobj)
                            continue
                        output.extend(chunk)
                        pending += chunk
                        while b"\n" in pending:
                            line, pending = pending.split(b"\n", 1)
                            if not capture:
                                self.log(self.clean(line.decode(errors="replace")))
                        require(len(output) < 64 * 1024 * 1024, "Command output exceeded 64 MiB")
                    if time.monotonic() - heartbeat >= 30:
                        self.log("Still running: " + self.clean(shlex.join(args[:4])))
                        heartbeat = time.monotonic()
                if pending and not capture:
                    self.log(self.clean(pending.decode(errors="replace")))
                try:
                    status = process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    raise ReleaseError("Command closed its output but did not exit") from None
                finished = True
            finally:
                selector.close()
                # A parent may already have exited while a grandchild retains
                # stdout. Timeout/cancellation still owns that process group.
                if not finished or process.poll() is None:
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
        text = output.decode(errors="replace")
        require(status == 0, f"Command failed ({status}): {self.clean(shlex.join(args[:5]))}\n{self.clean(text[-4000:])}")
        return text.strip()


def mach_minimum(data):
    """Read deployment load commands on either coordinator OS; never execute a NIF."""
    magic = data[:4]
    if magic in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        count = struct.unpack_from(">I", data, 4)[0]
        require(0 < count < 20, "Invalid universal Mach-O")
        stride = 32 if magic[-1] == 0xbf else 20
        result = []
        for index in range(count):
            start = 8 + index * stride
            offset = struct.unpack_from(">Q" if stride == 32 else ">I", data, start + 8)[0]
            result.extend(mach_minimum(data[offset:]))
        return result
    require(magic in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe"), "Unsupported Mach-O header")
    count = struct.unpack_from("<I", data, 16)[0]
    offset, result = (32 if magic[0] == 0xcf else 28), []
    require(count < 10000, "Invalid Mach-O command count")
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, offset)
        require(size >= 8 and offset + size <= len(data), "Invalid Mach-O load command")
        if command in (0x32, 0x24):
            value = struct.unpack_from("<I", data, offset + (12 if command == 0x32 else 8))[0]
            result.append((value >> 16, value >> 8 & 255, value & 255))
        offset += size
    require(bool(result), "Missing macOS deployment minimum")
    return result


def verify_inventory(directory):
    checksums = {}
    for line in (directory / "SHA256SUMS").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9_.-]+)", line)
        require(match is not None, "Invalid SHA256SUMS entry")
        digest, name = match.groups()
        require(name not in checksums, "Duplicate checksum entry")
        checksums[name] = digest
    actual = {path.name for path in directory.iterdir()}
    require(all(path.is_file() and not path.is_symlink() for path in directory.iterdir()),
            "Release inventory contains a link or directory")
    require(set(checksums) | {"SHA256SUMS"} | (actual & SIGNED) == actual,
            "Release inventory differs from SHA256SUMS")
    for name, digest in checksums.items():
        path = directory / name
        require(path.is_file() and not path.is_symlink() and sha256(path) == digest, f"Checksum mismatch: {name}")
    return checksums


class Release:
    def __init__(self, root, version, key, state_dir, runner=None, poll=30, wait=4 * 3600,
                 retry_failed=False, hex_get=None):
        self.root, self.version, self.key, self.directory = root, version, key, state_dir
        self.tag, self.poll, self.wait, self.retry_failed = "v" + version, poll, wait, retry_failed
        self.state_path = state_dir / "state.json"
        self.state = json.loads(self.state_path.read_text()) if self.state_path.exists() else {}
        require(isinstance(self.state, dict), "Release checkpoint must be a JSON object")
        require(not self.state or (self.state.get("schema_version"), self.state.get("repo"), self.state.get("version")) ==
                (1, REPO, version), "Release checkpoint belongs to a different release/schema")
        self.state.update(schema_version=1, repo=REPO, version=version)
        self.log_path = state_dir / (datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S") + "-" + uuid.uuid4().hex[:8] + ".log")
        self.log_file = self.log_path.open("a", buffering=1)
        self.run = runner or Runner(self.log, min(wait, 3600), key)
        self.hex_get = hex_get or self.hex_release
        self.scratch = self.source = None

    def log(self, text):
        line = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds") + " " + str(text)
        print(line, flush=True)
        self.log_file.write(line + "\n")

    def checkpoint(self, phase, **values):
        self.state.update(phase=phase, updated_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), **values)
        atomic_json(self.state_path, self.state)
        self.log("Phase: " + phase)

    def command(self, *args, cwd=None, capture=False):
        return self.run(args, cwd=cwd or self.source or self.root, capture=capture)

    def mix(self, *args, host=False, capture=False):
        return self.command("mise", "exec", "--", "mix", *args,
                            cwd=self.source / "dist/lmx" if host else self.source, capture=capture)

    def api(self, endpoint, absent=False):
        # `--include` lets us distinguish a real 404 from auth/network failures;
        # a CLI error without an HTTP status is never absence.
        for attempt in range(3):
            try:
                text = self.command("gh", "api", "--include", endpoint, capture=True)
                parts = text.replace("\r\n", "\n").split("\n\n", 1)
                require(len(parts) == 2, "GitHub returned an invalid HTTP response")
                body = parts[1]
                value = json.loads(body)
                require(isinstance(value, dict), "GitHub returned an invalid JSON object")
                return value
            except ReleaseError as error:
                if absent and re.search(r"HTTP/[\d.]+ 404\b", str(error)):
                    return None
                if attempt == 2:
                    raise
                self.log("Read failed; retrying: " + endpoint)
                time.sleep(min(self.poll, 5))

    def runs(self, workflow, event, sha):
        result = self.api(f"repos/{REPO}/actions/workflows/{workflow}/runs?head_sha={sha}&event={event}&per_page=100")
        return [run for run in result["workflow_runs"] if run["head_sha"] == sha and run["event"] == event]

    def await_run(self, workflow, event, sha, branch, dispatch=False):
        deadline, dispatched, retried = time.monotonic() + self.wait, False, False
        while time.monotonic() < deadline:
            runs = [run for run in self.runs(workflow, event, sha) if run["head_branch"] == branch]
            if not runs:
                if dispatch and not dispatched:
                    current = self.api(f"repos/{REPO}/git/ref/heads/main")
                    require(current["object"]["sha"] == sha,
                            "origin/main moved before rehearsal dispatch; qualify the pinned source before proceeding")
                    self.checkpoint("dispatch-rehearsal")
                    self.command("gh", "workflow", "run", workflow, "--repo", REPO, "--ref", "main")
                    dispatched = True
            else:
                run = max(runs, key=lambda run: run["id"])
                self.log(f"{workflow}: {run['html_url']} attempt {run['run_attempt']} — {run['status']} {run.get('conclusion') or ''}")
                if run["status"] == "completed":
                    if run["conclusion"] == "success":
                        return run
                    if self.retry_failed and not retried:
                        self.command("gh", "run", "rerun", str(run["id"]), "--repo", REPO, "--failed")
                        retried = True
                        # A rerun is eventually visible; wait for its new attempt.
                        while time.monotonic() < deadline:
                            current = self.api(f"repos/{REPO}/actions/runs/{run['id']}")
                            if current["run_attempt"] > run["run_attempt"]:
                                break
                            time.sleep(self.poll)
                    else:
                        raise ReleaseError(f"Workflow failed: {run['html_url']}. Inspect its logs; use --retry-failed to retry failed jobs once.")
            time.sleep(self.poll)
        raise ReleaseError(f"Timed out waiting for {workflow}; rerun this command to resume")

    def prepare(self):
        self.checkpoint("preflight", log=str(self.log_path))
        origin = self.command("git", "remote", "get-url", "origin", capture=True)
        require(origin_repo(origin) == REPO, "origin must point to " + REPO)
        permissions = self.api(f"repos/{REPO}")
        require(not permissions["private"] and permissions.get("permissions", {}).get("push"),
                "Authenticated gh needs write access to the public release repository")
        actor = self.api("user")
        require(isinstance(actor.get("id"), int) and actor["id"] > 0 and
                re.fullmatch(r"[A-Za-z0-9-]+", actor.get("login", "")), "Invalid GitHub maintainer identity")
        self.command("git", "clone", "--no-checkout", origin, str(self.scratch / "source"))
        self.source = self.scratch / "source"
        # A fresh clone has no repository-local identity. Use gh's public
        # identity, without exposing an email or prompting for a GPG key.
        self.command("git", "config", "user.name", actor["login"])
        self.command("git", "config", "user.email", f"{actor['id']}+{actor['login']}@users.noreply.github.com")
        tags = self.command("git", "tag", "--list", self.tag, capture=True).splitlines()
        ref = self.tag if tags else self.state.get("source_sha", "origin/main")
        sha = self.command("git", "rev-parse", ref + "^{commit}", capture=True)
        require(not self.state.get("source_sha") or self.state["source_sha"] == sha,
                "Source/tag moved since this release started; refusing to change the checkpointed source")
        self.command("git", "merge-base", "--is-ancestor", sha, "origin/main")
        self.command("git", "switch", "--detach", sha)
        if tags:
            require(self.command("git", "cat-file", "-t", self.tag, capture=True) == "tag",
                    "Existing release tag must be annotated")
        require((self.source / "VERSION").read_text().strip() == self.version, "Requested version differs from source VERSION")
        self.checkpoint("source-pinned", source_sha=sha)
        self.log("Release source: " + sha)
        self.command("mise", "install")
        self.mix("local.hex", "--if-missing", "--force")
        self.mix("local.rebar", "--if-missing", "--force")
        self.mix("deps.get")
        self.mix("deps.get", host=True)
        self.mix("run", "--no-start", "-e", KEY_CHECK, host=True)
        self.mix("hex.user", "whoami")
        latest = self.api(f"repos/{REPO}/releases/latest", absent=True)
        if latest:
            latest_version = latest["tag_name"][1:]
            require(STABLE.fullmatch(latest_version) and tuple(map(int, latest_version.split("."))) <=
                    tuple(map(int, self.version.split("."))), "Refusing to release an older version than latest")
        if not latest or latest["tag_name"] != self.tag:
            self.mix("lmx.upgrade.check", "--latest", latest["tag_name"][1:] if latest else "none", host=True)
        for workflow in ("ci.yml", "public-readiness.yml"):
            self.await_run(workflow, "push", sha, "main")
        return tags, latest

    def tag_release(self, tags):
        sha = self.state["source_sha"]
        if not tags:
            rehearsal = self.await_run("release.yml", "workflow_dispatch", sha, "main", dispatch=True)
            candidate = self.scratch / "rehearsal"
            self.command("gh", "run", "download", str(rehearsal["id"]), "--repo", REPO,
                         "--name", "complete-release-candidate", "--dir", str(candidate))
            self.validate_candidate(candidate)
            self.checkpoint("rehearsal-passed", rehearsal_run=rehearsal["id"])
            self.command("git", "tag", "-a", "--no-sign", self.tag, "-m", "Lemieux " + self.version)
            self.checkpoint("push-tag")
            self.command("git", "push", "origin", "refs/tags/" + self.tag)
        run = self.await_run("release.yml", "push", sha, self.tag)
        require(run.get("path") == ".github/workflows/release.yml", "Unexpected release workflow path")
        self.checkpoint("tag-run-passed", run_id=run["id"], run_attempt=run["run_attempt"], run_url=run["html_url"])
        return run

    def download_release(self, directory, tag=None, patterns=()):
        arguments = ["gh", "release", "download", tag or self.tag, "--repo", REPO, "--dir", str(directory)]
        for pattern in patterns:
            arguments.extend(("--pattern", pattern))
        self.command(*arguments)

    def snapshot(self, directory):
        return {path.name: sha256(path) for path in directory.iterdir() if path.name not in SIGNED}

    def validate_candidate(self, candidate):
        checksums = verify_inventory(candidate)
        required = {*(f"lmx_{target}.tar.gz" for target in TARGETS),
                    *(f"upgrade-report-{target}.json" for target in TARGETS),
                    "LICENSE", "NOTICE", "release-notes.md", "install.py", "install.sh", "upgrade-plan.exs", "update.json"}
        require(set(checksums) == required, "Incomplete or unexpected candidate inventory")
        source_files = {"LICENSE": "LICENSE", "NOTICE": "NOTICE", "release-notes.md": ".github/release-notes.md",
                        "install.py": "scripts/install.py", "install.sh": "scripts/install.sh",
                        "upgrade-plan.exs": f"dist/lmx/upgrades/{self.version}.exs"}
        for name, source in source_files.items():
            require((candidate / name).read_bytes() == (self.source / source).read_bytes(), "Source mismatch: " + name)
        manifest = json.loads((candidate / "update.json").read_text())
        require(manifest["schema_version"] == 1 and manifest["version"] == self.version and
                set(manifest["targets"]) == set(TARGETS), "Unexpected update manifest")
        reports = {target: json.loads((candidate / f"upgrade-report-{target}.json").read_text()) for target in TARGETS}
        previous_versions = {report["from"]["version"] for report in reports.values()}
        require(len(previous_versions) == 1, "Qualification reports disagree on predecessor")
        previous = previous_versions.pop()
        require(STABLE.fullmatch(previous), "Invalid predecessor version")
        self.mix("lmx.upgrade.check", "--latest", previous, host=True)
        predecessor = self.scratch / "previous"
        if not predecessor.exists():
            self.download_release(predecessor, "v" + previous, ("SHA256SUMS", "SHA256SUMS.sig", "update.json", "update.json.sig"))
        public_key = self.command("git", "show", "v" + previous + ":dist/lmx/release-signing.pub", capture=True)
        self.mix("lmx.release.verify", "--public-key", public_key, str(predecessor / "SHA256SUMS"),
                 str(predecessor / "update.json"), host=True)
        previous_manifest = json.loads((predecessor / "update.json").read_text())
        require(previous_manifest.get("version") == previous and set(previous_manifest.get("targets", {})) == set(TARGETS),
                "Signed predecessor manifest has an unexpected identity")
        minima = []
        for target, info in manifest["targets"].items():
            name = f"lmx_{target}.tar.gz"
            with tarfile.open(candidate / name, "r:gz") as archive:
                identities = [entry for entry in archive.getmembers() if re.fullmatch(r"releases/[^/]+/release.json", entry.name)]
                require(len(identities) == 1 and identities[0].size < 100_000, "Invalid archive release identity")
                identity = json.load(archive.extractfile(identities[0]))
                require(dict(identity, sha256=checksums[name]) == info and info["target"] == target and info["version"] == self.version,
                        "Archive/manifest mismatch: " + target)
                require(release_checksums.updater_entry_problem(info) is None, "Invalid updater entry: " + target)
                names = {entry.name for entry in archive.getmembers()}
                if info["upgrade_from"]:
                    require({f"releases/{self.version}/relup", f"lib/lemieux-{self.version}/ebin/lemieux.appup",
                             f"lib/lmx-{self.version}/ebin/lmx.appup"} <= names, "Hot archive lacks relup/appups")
                else:
                    require(not info["hot_modules"] and not any(name.endswith("/relup") for name in names),
                            "Restart archive declares hot modules or relup")
                if target != "windows":
                    require(not release_checksums.unstable_modes(archive), "Archive extraction modes differ: " + target)
                if target.startswith("macos"):
                    for entry in archive.getmembers():
                        if entry.isfile() and (entry.name.endswith("/bin/beam.smp") or entry.name.endswith(".so")):
                            minima.extend(mach_minimum(archive.extractfile(entry).read()))
            report = reports[target]
            old = previous_manifest["targets"][target]
            require(report["to"] == info and report["target"] == target and report["candidate_sha256"] == info["sha256"]
                    and report["plan_sha256"] == checksums["upgrade-plan.exs"] and report["previous_sha256"] == old["sha256"]
                    and report["from"] == {key: value for key, value in old.items() if key != "sha256"}
                    and report["cold_boot"] is True and report["tools_and_transcript_resume"] is True,
                    "Qualification mismatch: " + target)
            require(report["windows_manual_restart"] is True if target == "windows" else report["restart_install"] is True,
                    "Restart qualification missing: " + target)
            if info["upgrade_from"]:
                required_hot = ("live_hot_upgrade", "live_downgrade", "live_session_survived", "unsent_draft_preserved",
                                "interrupted_preparation_fallback", "failed_health_rolled_back", "failed_build_quarantined")
                require(all(report.get(field) is True for field in required_hot) and
                        {"version": previous, "build_id": old["build_id"]} in info["upgrade_from"], "Hot qualification missing")
        note = re.search(r"macOS (\d+(?:\.\d+)*) or later", (candidate / "release-notes.md").read_text())
        require(note is not None and minima, "Release notes or archives lack a macOS minimum")
        declared = tuple((list(map(int, note.group(1).split("."))) + [0, 0])[:3])
        require(max(minima) == declared, "Packaged macOS minimum differs from release notes")
        self.checkpoint("candidate-verified", inventory=self.snapshot(candidate), archive_checksums=checksums,
                        previous_version=previous, macos_minimum=declared)

    def assert_current_run(self, expected):
        runs = [run for run in self.runs("release.yml", "push", self.state["source_sha"]) if run["head_branch"] == self.tag]
        latest = max(runs, key=lambda run: run["id"]) if runs else {}
        require((latest.get("id"), latest.get("run_attempt"), latest.get("conclusion"), latest.get("status")) ==
                (expected["id"], expected["run_attempt"], "success", "completed"),
                "Release workflow changed; rerun this script to qualify its current artifacts")

    def release_info(self):
        # REST /releases/tags/TAG only returns published releases. gh resolves
        # authenticated drafts too; normalize its field names for both states.
        info = json.loads(self.command("gh", "release", "view", self.tag, "--repo", REPO,
                                       "--json", "databaseId,tagName,isDraft,isPrerelease,url", capture=True))
        require(isinstance(info, dict) and info.get("tagName") == self.tag and
                type(info.get("databaseId")) is int and info["databaseId"] > 0 and
                isinstance(info.get("isDraft"), bool) and isinstance(info.get("isPrerelease"), bool) and
                isinstance(info.get("url"), str) and info["url"].startswith(f"https://github.com/{REPO}/releases/"),
                "GitHub returned an invalid release identity")
        return {"id": info["databaseId"], "tag_name": info["tagName"], "draft": info["isDraft"],
                "prerelease": info["isPrerelease"], "html_url": info["url"]}

    def verified_draft(self, directory, expected, signed=False):
        self.assert_current_run(expected)
        self.download_release(directory)
        verify_inventory(directory)
        require(self.snapshot(directory) == self.state["inventory"], "Draft changed from the qualified workflow artifact")
        if signed:
            require(SIGNED <= {path.name for path in directory.iterdir()}, "Release lacks both signatures")
            self.mix("lmx.release.verify", str(directory / "SHA256SUMS"), str(directory / "update.json"), host=True)
        return self.release_info()

    def attest(self, directory):
        for name in (*release_checksums.ARTIFACTS, "SHA256SUMS", "update.json"):
            self.command("gh", "attestation", "verify", str(directory / name), "--repo", REPO,
                         "--source-ref", "refs/tags/" + self.tag,
                         "--signer-workflow", REPO + "/.github/workflows/release.yml")

    def hex_release(self):
        request = urllib.request.Request(f"https://hex.pm/api/packages/lemieux/releases/{self.version}",
                                         headers={"User-Agent": "lemieux-release-driver", "Accept": "application/json"})
        for attempt in range(3):
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    return json.load(response)
            except urllib.error.HTTPError as error:
                if error.code == 404:
                    return None
                if error.code < 500:
                    raise ReleaseError(f"Hex read failed: HTTP {error.code}") from None
            except urllib.error.URLError:
                pass
            if attempt < 2:
                time.sleep(min(self.poll, 5))
        raise ReleaseError("Hex is unavailable; publication state is unknown. Rerun to reconcile before publishing.")

    def publish_hex(self):
        self.checkpoint("prepare-hex")
        self.mix("hex.publish", "--dry-run")
        package = self.scratch / ("lemieux-" + self.version + ".tar")
        self.mix("hex.build", "--output", str(package))
        tracked = set(self.command("git", "ls-files", capture=True).splitlines())
        with tarfile.open(package) as outer:
            with tarfile.open(fileobj=outer.extractfile("contents.tar.gz"), mode="r:gz") as contents:
                for entry in contents.getmembers():
                    if not entry.isfile():
                        require(entry.isdir(), "Hex package contains a link or special file")
                        continue
                    name = str(PurePosixPath(entry.name))
                    require(name in tracked and ".." not in PurePosixPath(name).parts,
                            "Untracked file in Hex package: " + name)
                    require(contents.extractfile(entry).read() == (self.source / name).read_bytes(),
                            "Hex package differs from source: " + name)
        digest = sha256(package)
        require(not self.state.get("hex_checksum") or self.state["hex_checksum"] == digest,
                "Hex package bytes changed since the previous attempt")
        self.checkpoint("hex-ready", hex_checksum=digest)
        release = self.hex_get()
        if release is None:
            self.checkpoint("publish-hex")
            self.mix("hex.publish", "--yes")
        else:
            require(release.get("checksum") == digest and not release.get("retirement"),
                    "Existing Hex version differs from this source or is retired; refusing overwrite")
            if not release.get("has_docs"):
                self.mix("hex.publish", "docs", "--yes")
        deadline = time.monotonic() + min(self.wait, 180)
        while time.monotonic() < deadline:
            release = self.hex_get()
            if release:
                require(release.get("checksum") == digest and not release.get("retirement"), "Published Hex checksum mismatch")
                if release.get("has_docs"):
                    self.checkpoint("hex-published")
                    return
            time.sleep(self.poll)
        raise ReleaseError("Hex package/docs not yet confirmed; rerun to reconcile")

    def execute(self):
        tags, latest = self.prepare()
        run = self.tag_release(tags)
        qualified = (self.state.get("qualified_run_id"), self.state.get("qualified_run_attempt"))
        if qualified != (run["id"], run["run_attempt"]):
            candidate = self.scratch / "candidate"
            self.command("gh", "run", "download", str(run["id"]), "--repo", REPO,
                         "--name", "complete-release-candidate", "--dir", str(candidate))
            self.validate_candidate(candidate)
            self.checkpoint("tag-candidate-verified", qualified_run_id=run["id"], qualified_run_attempt=run["run_attempt"])
        # Artifacts expire. Retained hashes are bound to the exact successful
        # run AND attempt. Always re-download the release and verify every byte,
        # signature and attestation; a workflow rerun requires new qualification.
        draft = self.scratch / "draft"
        release = self.verified_draft(draft, run)
        if release["draft"]:
            self.checkpoint("sign-draft")
            self.mix("lmx.release.sign_draft", "--tag", self.tag, "--private-key", str(self.key), "--repo", REPO, host=True)
        signed = self.scratch / "signed"
        self.verified_draft(signed, run, signed=True)
        self.attest(signed)
        self.publish_hex()
        # Hex upload can take time. Re-download immediately before publication:
        # a concurrent workflow rerun deletes signatures and replaces the draft.
        final = self.scratch / "final"
        release = self.verified_draft(final, run, signed=True)
        latest = self.api(f"repos/{REPO}/releases/latest", absent=True)
        if latest and latest["tag_name"] != self.tag:
            value = latest["tag_name"][1:]
            require(STABLE.fullmatch(value) and tuple(map(int, value.split("."))) < tuple(map(int, self.version.split("."))),
                    "A newer GitHub release exists; refusing to change latest")
        if release["draft"] or release["prerelease"] or not latest or latest["tag_name"] != self.tag:
            self.checkpoint("publish-github")
            self.command("gh", "release", "edit", self.tag, "--repo", REPO,
                         "--draft=false", "--prerelease=false", "--latest")
        published = self.release_info()
        latest = self.api(f"repos/{REPO}/releases/latest")
        require(not published["draft"] and not published["prerelease"] and latest["tag_name"] == self.tag,
                "GitHub publication/latest was not confirmed; rerun to reconcile")
        self.checkpoint("complete", release_url=published["html_url"], error=None)
        self.log("Released " + self.tag + ": " + published["html_url"])

    def cleanup(self):
        old = self.state.get("scratch")
        if old:
            path = Path(old)
            marker = path / ".release-owner.json"
            if path.exists():
                owner = self.state.get("scratch_owner")
                require(isinstance(owner, dict) and owner.get("repo") == REPO and owner.get("version") == self.version
                        and isinstance(owner.get("id"), str) and re.fullmatch(r"[0-9a-f]{32}", owner["id"])
                        and path.parent == Path(tempfile.gettempdir()).resolve() and path.name == "lemieux-release-" + owner["id"]
                        and path.is_dir() and not path.is_symlink() and path.stat().st_uid == os.getuid()
                        and (not marker.exists() or (marker.is_file() and json.loads(marker.read_text()) == owner)),
                        "Temporary directory ownership differs; refusing cleanup: " + str(path))
                shutil.rmtree(path)
            self.state.pop("scratch", None)
            self.state.pop("scratch_owner", None)
            atomic_json(self.state_path, self.state)

    def start(self):
        self.log("Log: " + str(self.log_path))
        try:
            self.cleanup()
            owner = {"repo": REPO, "version": self.version, "id": uuid.uuid4().hex}
            self.scratch = Path(tempfile.gettempdir()).resolve() / ("lemieux-release-" + owner["id"])
            # Reserve the exact unpredictable path durably BEFORE mkdir. A
            # kill between mkdir and writing its marker is then recoverable.
            self.checkpoint("starting", scratch=str(self.scratch), scratch_owner=owner)
            self.scratch.mkdir(mode=0o700)
            atomic_json(self.scratch / ".release-owner.json", owner)
            self.execute()
        except (ReleaseError, OSError, ValueError, KeyError, TypeError, IndexError,
                struct.error, tarfile.TarError, KeyboardInterrupt) as error:
            message = "Interrupted; rerun the same command to resume" if isinstance(error, KeyboardInterrupt) else str(error)
            if isinstance(self.run, Runner):
                message = self.run.clean(message)
            self.checkpoint("stopped", error=message)
            self.log("ERROR: " + message)
            raise ReleaseError(message) from None
        finally:
            try:
                self.cleanup()
            finally:
                self.log("Log: " + str(self.log_path))
                self.log_file.close()


@contextlib.contextmanager
def release_lock(path):
    # Never unlink a flock file: a waiter may hold its inode while a new
    # caller opens a replacement, admitting two maintainers simultaneously.
    with path.open("a") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ReleaseError("Another local release is running") from None
        try:
            yield
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Release Lemieux from origin/main; rerun identical arguments to resume.")
    parser.add_argument("version", help="stable X.Y.Z or vX.Y.Z")
    parser.add_argument("key", type=Path, help="existing offline release key outside every checkout")
    parser.add_argument("--retry-failed", action="store_true", help="retry failed workflow jobs once")
    parser.add_argument("--timeout", type=int, default=14400, help="maximum seconds per workflow wait (default: 14400)")
    args = parser.parse_args(argv)
    version = args.version[1:] if args.version.startswith("v") else args.version
    try:
        require(STABLE.fullmatch(version) and len(version) < 128, "Version must be stable X.Y.Z")
        require(60 <= args.timeout <= 86400, "--timeout must be between 60 and 86400 seconds")
        require(platform.system() in ("Darwin", "Linux"), "Run the coordinator on macOS or Linux")
        for tool in ("git", "gh", "mise"):
            require(shutil.which(tool), "Required command is missing: " + tool)
        key = validate_key_path(args.key)
        common = subprocess.check_output(["git", "rev-parse", "--git-common-dir"], cwd=ROOT, text=True).strip()
        directory = (ROOT / common).resolve() / "lmx-releases"
        os.umask(0o077)
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        with release_lock(directory / "release.lock"):
            state = directory / version
            state.mkdir(mode=0o700, exist_ok=True)
            def interrupted(_signum, _frame):
                raise KeyboardInterrupt()
            for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                signal.signal(signum, interrupted)
            Release(ROOT, version, key, state, wait=args.timeout, retry_failed=args.retry_failed).start()
        return 0
    except (ReleaseError, subprocess.CalledProcessError, OSError, ValueError) as error:
        print("Release stopped: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
