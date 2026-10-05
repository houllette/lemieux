"""Require the complete native artifact set and write update.json and SHA256SUMS. No publishing, no signing.

The release key stays offline, so this never signs anything: it writes the two
files the maintainer signs afterwards (`mix lmx.release.sign_draft`) and says
so. Each signature has one consumer: installed lmx builds refuse to install
the release until update.json.sig exists, and install.py (with install.sh)
refuses to install it until SHA256SUMS.sig exists.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tarfile

TARGETS = ("linux", "macos", "macos_silicon", "windows")
ARTIFACTS = tuple(f"lmx_{target}.tar.gz" for target in TARGETS)
SIGNED = ("SHA256SUMS", "update.json")
DIGEST = re.compile(r"[0-9a-f]{64}")
STABLE = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")


def stable(version):
    """The X.Y.Z version as a tuple, or None for anything else (pre-releases, build metadata)."""
    if not isinstance(version, str) or len(version) > 128 or not STABLE.fullmatch(version):
        return None
    return tuple(int(part) for part in version.split("."))


def updater_entry_problem(info):
    """What Lmx.Update.select/2 would reject in a target entry, or None.

    Every installed lmx validates its entry this way before trusting it; a
    manifest that fails here would be signed and published, then refused by
    every updater. The entry's target and the manifest's version are checked
    by the caller, which knows them.
    """
    version = stable(info.get("version"))
    if version is None:
        return f"version {info.get('version')!r} is not a stable X.Y.Z version"
    for key in ("sha256", "build_id", "native_id", "dependency_id", "config_id"):
        if not isinstance(info.get(key), str) or not DIGEST.fullmatch(info[key]):
            return f"{key} is not a SHA-256 digest"
    for key in ("erts", "elixir"):
        if not isinstance(info.get(key), str) or not info[key]:
            return f"{key} is missing"
    dependencies = info.get("dependencies")
    if not isinstance(dependencies, dict) or not all(
            isinstance(name, str) and isinstance(version, str) for name, version in dependencies.items()):
        return "dependencies is not a map of names to versions"
    modules = info.get("hot_modules")
    if not isinstance(modules, list) or not all(isinstance(module, str) for module in modules):
        return "hot_modules is not a list of module names"
    predecessors = info.get("upgrade_from")
    if not isinstance(predecessors, list) or len(predecessors) > 32:
        return "upgrade_from is not a list of at most 32 predecessors"
    for item in predecessors:
        # Lmx.Update's predecessors?/2: an older stable version and its build digest.
        if (not isinstance(item, dict) or not isinstance(item.get("build_id"), str) or
                not DIGEST.fullmatch(item["build_id"]) or stable(item.get("version")) is None or
                stable(item["version"]) >= version):
            return f"upgrade_from entry {item!r} is not an older stable version with a build digest"
    return None


def packed_mode(mode):
    """The mode Lmx.Release.normalize_modes/1 gives a file, which every extractor reproduces.

    It is what Python's "data" filter would leave (install.py's
    canonical_mode). Release builds refuse an archive with other modes; this
    checks the candidate again, so an archive built some other way cannot
    reach a draft.
    """
    kept = mode & 0o755
    if not kept & 0o100:
        kept &= ~0o111
    return kept | 0o600


def unstable_modes(archive):
    """Files in a Unix archive whose mode install.py and the updater would extract differently."""
    return [f"{entry.name} ({entry.mode & 0o7777:04o})" for entry in archive.getmembers()
            if entry.isfile() and entry.mode & 0o7777 != packed_mode(entry.mode)]


def main():
    directory = Path(sys.argv[1])
    for name in ARTIFACTS:
        path = directory / name
        if not path.is_file() or path.stat().st_size == 0:
            raise SystemExit(f"Missing or empty release artifact: {name}")
    targets = {}
    for target, name in zip(TARGETS, ARTIFACTS):
        with tarfile.open(directory / name, "r:gz") as archive:
            candidates = [entry for entry in archive.getmembers()
                          if entry.name.startswith("releases/") and entry.name.endswith("/release.json")]
            if len(candidates) != 1 or candidates[0].size > 100_000:
                raise SystemExit(f"Invalid release identity in {name}")
            # Erlang on Windows reports every writable file as 0666, and
            # nothing extracts that archive into a version directory.
            unstable = unstable_modes(archive) if target != "windows" else []
            if unstable:
                raise SystemExit(f"{name} has modes install.py and lmx's updater would extract differently, "
                                 "so neither would reuse a version directory the other made: "
                                 + ", ".join(unstable[:5]) + (", ..." if len(unstable) > 5 else ""))
            info = json.load(archive.extractfile(candidates[0]))
            if info["target"] != target:
                raise SystemExit(f"Wrong platform in {name}")
            info["sha256"] = hashlib.sha256((directory / name).read_bytes()).hexdigest()
            problem = updater_entry_problem(info)
            if problem:
                raise SystemExit(f"Release identity in {name} would be rejected by lmx's updater: {problem}")
            targets[target] = info
    versions = {info["version"] for info in targets.values()}
    if len(versions) != 1:
        raise SystemExit("Release versions do not match")
    plan = directory / "upgrade-plan.exs"
    if not plan.is_file():
        raise SystemExit("Missing reviewed upgrade-plan.exs")
    plan_sha = hashlib.sha256(plan.read_bytes()).hexdigest()
    previous = os.environ.get("LMX_PREVIOUS_RELEASE")
    reports = []
    for target, info in targets.items():
        report_name = f"upgrade-report-{target}.json"
        report_path = directory / report_name
        if previous or info["upgrade_from"]:
            if not report_path.is_file():
                raise SystemExit(f"Missing actual artifact qualification: {report_name}")
            report = json.loads(report_path.read_text())
            expected_to = dict(info)
            if (report.get("to") != expected_to or report.get("target") != target or
                report.get("candidate_sha256") != info["sha256"] or
                report.get("plan_sha256") != plan_sha or
                not report.get("tools_and_transcript_resume") or not report.get("cold_boot") or
                (target != "windows" and not report.get("restart_install")) or
                (previous and report.get("from", {}).get("version") != previous)):
                raise SystemExit(f"Qualification does not match candidate/plan: {report_name}")
            if info["upgrade_from"]:
                source = {"version": report["from"]["version"], "build_id": report["from"]["build_id"]}
                if (source not in info["upgrade_from"] or not report.get("live_hot_upgrade") or
                    not report.get("live_downgrade") or not report.get("live_session_survived") or
                    not report.get("unsent_draft_preserved") or
                    report.get("interrupted_preparation_fallback") is not True or
                    report.get("failed_health_rolled_back") is not True or
                    report.get("failed_build_quarantined") is not True):
                    raise SystemExit(f"Hot path lacks exact upgrade/downgrade qualification: {report_name}")
            reports.append(report_name)
    version = versions.pop()
    manifest = {"schema_version": 1, "version": version, "targets": targets}
    # Installed builds verify update.json.sig over these exact bytes, so the
    # file is written once here and never rewritten after signing.
    (directory / "update.json").write_text(json.dumps(manifest, indent=2) + "\n")
    names = (*ARTIFACTS, "LICENSE", "NOTICE", "release-notes.md", "update.json", "install.py", "install.sh", "upgrade-plan.exs", *reports)
    lines = [f"{hashlib.sha256((directory / name).read_bytes()).hexdigest()}  {name}\n"
             for name in names]
    (directory / "SHA256SUMS").write_text("".join(lines))
    print("Verified complete release inventory and wrote update.json and SHA256SUMS.")
    print("Not yet signed: add " + " and ".join(f"{name}.sig" for name in SIGNED) +
          " to the draft before publishing. Installed lmx installs nothing without update.json.sig, "
          "and install.py installs nothing without SHA256SUMS.sig.")
    print(f"From dist/lmx, with the offline key: mix lmx.release.sign_draft --tag v{version} --private-key PATH")


if __name__ == "__main__":
    main()
