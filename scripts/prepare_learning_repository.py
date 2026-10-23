#!/usr/bin/env python3
"""Prepare a SWE-derived development fixture; sends no model requests.

The cached source image supplies an exact Git archive, never its current HEAD.
The prepared image must already contain the project interpreter and pytest,
with /testbed and its Git history removed. It is resolved to an immutable ID.
A separately supplied public check is curator-owned verification, not a learned
candidate. Private test/gold patches remain outside every agent source tree.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile


def run(argv, *, cwd=None, timeout=180):
    return subprocess.run(argv, cwd=cwd, capture_output=True, check=True, timeout=timeout).stdout


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def safe_extract(data, destination):
    if len(data) > 128_000_000:
        raise ValueError("archive exceeds preparation bound")
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        members = archive.getmembers()
        if len(members) > 25_000 or sum(m.size for m in members) > 256_000_000:
            raise ValueError("expanded archive exceeds preparation bound")
        for member in members:
            path = PurePosixPath(member.name)
            if (path.is_absolute() or ".." in path.parts or
                    not (member.isfile() or member.isdir()) or member.size > 16_000_000):
                raise ValueError(f"unsafe archive member: {member.name}")
        archive.extractall(destination, members=members, filter="data")


def file_digests(directory):
    result = {}
    for path in directory.rglob("*"):
        relative = path.relative_to(directory)
        if ".git" in relative.parts:
            continue
        if path.is_symlink():
            raise ValueError("patch/source contains a symlink")
        if path.is_file():
            result[str(relative)] = digest(path)
    return result


def apply_patch(directory, patch):
    # git apply below a different repository can silently skip a patch while
    # returning zero. Own a temporary repository and require actual changed bytes.
    directory = directory.resolve()
    if (directory / ".git").exists():
        raise ValueError("patch destination already contains Git metadata")
    before = file_digests(directory)
    run(["git", "-c", "init.templateDir=", "init", "-q", str(directory)])
    try:
        run(["git", "-C", str(directory), "apply", "--check", str(patch.resolve())])
        run(["git", "-C", str(directory), "apply", str(patch.resolve())])
    finally:
        shutil.rmtree(directory / ".git")
    after = file_digests(directory)
    changed = sorted(p for p in set(before) | set(after) if before.get(p) != after.get(p))
    if not changed:
        raise ValueError("patch changed no source bytes")
    return changed


def verification_file(path):
    return (path.name.startswith("test_") or path.name == "conftest.py" or
            "tests" in path.parts or path.suffix in {".md", ".rst", ".sh", ".lock"} or
            path.name in {"Makefile", "setup.cfg", "setup.py", "pyproject.toml", "pytest.ini"})


def project_oracle(source, oracle, patch, frozen):
    """Apply the reference implementation under the same immutable contract."""
    shutil.copytree(source, oracle)
    apply_patch(oracle, patch)
    for name in frozen:
        target = oracle / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / name, target)


def pytest_selection(selectors):
    """Select complete function families; oracle controls freeze actual counts.

    Node IDs retain their test-file closure. Parameter variants and identically
    named functions in the copied files are all tested, not official benchmark
    parity. Never interpolate raw dataset selectors into pytest configuration.
    """
    paths, names = set(), []
    if not selectors:
        raise ValueError("empty pytest selection")
    for selector in selectors:
        parts = selector.split("::")
        name = parts[-1].split("[", 1)[0]
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
            raise ValueError("unsupported pytest function selector")
        if len(parts) > 1:
            path = PurePosixPath(parts[0])
            if (path.suffix != ".py" or path.is_absolute() or
                    any(p in {"", ".", ".."} or not re.fullmatch(r"[A-Za-z0-9_.-]+", p)
                        for p in parts[0].split("/")) or
                    not all(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", p) for p in parts[1:-1])):
                raise ValueError("unsafe or unsupported pytest node ID")
            paths.add(str(path))
        if name not in names:
            names.append(name)
    return sorted(paths), names


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--instance", required=True)
    parser.add_argument("--source-image", required=True, help="cached repository@sha256:digest")
    parser.add_argument("--image", required=True, help="cached prepared sha256:image ID")
    parser.add_argument("--public-check", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if "@sha256:" not in args.source_image or not args.image.startswith("sha256:"):
        parser.error("source and prepared images require immutable identities")
    items = json.loads(args.dataset.read_bytes())
    matches = [item for item in items if item["instance_id"] == args.instance]
    if len(matches) != 1:
        parser.error("instance must occur exactly once in the private dataset")
    instance = matches[0]
    base = instance["base_commit"]
    if not re.fullmatch(r"[a-f0-9]{40}", base):
        parser.error("invalid task base commit")
    image = json.loads(run(["docker", "image", "inspect", args.image, "--format", "{{json .}} "]))
    environment = dict(x.split("=", 1) for x in image["Config"]["Env"] if "=" in x)
    if environment.get("PYTHONDONTWRITEBYTECODE") != "1" or "no:cacheprovider" not in environment.get("PYTEST_ADDOPTS", ""):
        parser.error("prepared image must disable Python bytecode and pytest cache writes")
    run(["docker", "run", "--rm", "--network", "none", "--read-only", "--entrypoint", "sh",
         args.image, "-c", "test ! -e /testbed && python3 -I -B -c 'import pytest'"], timeout=30)
    root = args.output.resolve()
    root.mkdir(mode=0o700, parents=True, exist_ok=False)
    # This output is private curation state. Never point an agent at its parent.
    (root / "instance.private.json").write_text(json.dumps(instance, indent=2) + "\n")
    os.chmod(root / "instance.private.json", 0o600)
    archive = run(["docker", "run", "--rm", "--network", "none", "--read-only",
                   "--entrypoint", "git", args.source_image, "-C", "/testbed", "archive", base])
    public_check = args.public_check.read_bytes()
    source = root / "source"
    safe_extract(archive, source)
    (root / "source.tar").write_bytes(archive)
    (source / "test_qualification_public.py").write_bytes(public_check)
    (source / "qualification_pytest.ini").write_text("[pytest]\naddopts = -q -p no:cacheprovider\n")
    frozen = sorted(str(p.relative_to(source)) for p in source.rglob("*")
                    if p.is_file() and verification_file(p.relative_to(source)))
    frozen = sorted(set(frozen) | {"qualification_pytest.ini", "qualification-contract.json"})
    (source / "qualification-contract.json").write_text(json.dumps(
        {"schema_version": 1, "paths": frozen}, indent=2) + "\n")
    patches = {}
    for role, key in [("tests", "test_patch"), ("gold", "patch")]:
        path = root / f"{role}.private.patch"
        path.write_text(instance[key])
        patches[role] = path
    preparation = root / "private-test-preparation"
    shutil.copytree(source, preparation)
    changed_tests = apply_patch(preparation, patches["tests"])
    selected_paths, selectors = pytest_selection(instance["FAIL_TO_PASS"] + instance["PASS_TO_PASS"])
    private = root / "private-tests"
    private.mkdir()
    selected_files = set(changed_tests) | set(selected_paths)
    for name in list(selected_files):
        for parent in PurePosixPath(name).parents:
            candidate = str(parent / "conftest.py")
            if (preparation / candidate).is_file():
                selected_files.add(candidate)
    for name in sorted(selected_files):
        path = PurePosixPath(name)
        if not verification_file(path) or not (preparation / name).is_file():
            raise ValueError(f"unsupported private test change: {name}")
        target = private / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(preparation / name, target)
    if (source / "conftest.py").is_file():
        shutil.copyfile(source / "conftest.py", private / "conftest.py")
    (private / "pytest.ini").write_text('[pytest]\naddopts = -k "' + ' or '.join(selectors) + '"\n')
    oracle = root / "oracle"
    project_oracle(source, oracle, patches["gold"], frozen)
    template = {
        "schema_version": 1,
        "metadata": {
            "id": args.instance + "-development", "exposure": "developer_exposed",
            "base_commit": base, "dataset_sha256": digest(args.dataset),
            "source_image": args.source_image, "source_archive_sha256": hashlib.sha256(archive).hexdigest(),
            "public_check_sha256": hashlib.sha256(public_check).hexdigest(),
            "grading": "SWE-derived private pytest subset; not the official SWE-bench evaluator",
            "selectors_policy": "complete_function_families_in_selected_files/v1",
            "oracle_policy": "reference_implementation_with_original_immutable_bytes/v1",
            "independent_confirmation": "not_run",
        },
        "tasks": [{
            "id": args.instance.replace("__", "-"), "cluster": instance["repo"].replace("/", "-"),
            "phase": "learning", "source": str(source), "private_tests": str(private),
            "image": args.image, "immutable_paths": frozen,
            "immutable_contract": "qualification-contract.json",
            "public_pytest_args": ["-c", "qualification_pytest.ini", "test_qualification_public.py"],
            "prompt": instance["problem_statement"] +
                "\nThe repository is at /app. Use its existing Python environment. "
                "Reproduce with python3 -m pytest -c qualification_pytest.ini test_qualification_public.py, "
                "inspect neighboring implementations, repair the cause and verify relevant regressions."
        }]
    }
    (root / "template.json").write_text(json.dumps(template, indent=2) + "\n")
    repo = Path(__file__).resolve().parents[1]
    run(["mix", "run", "scripts/freeze_learning_repository.exs", "--template", str(root / "template.json")],
        cwd=repo, timeout=1200)
    print(f"Prepared development fixture and control evidence: {root / 'manifest.json'}")


if __name__ == "__main__":
    main()
