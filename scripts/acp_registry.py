"""Prepare an ACP Registry submission from a released version's SHA256SUMS.

This writes metadata only. Qualify the archives and terminal authentication
before submitting the generated entry to the upstream registry.
"""
import argparse
import json
from pathlib import Path
import re
import shutil


REPOSITORY = "https://github.com/houllette/lemieux"
PLATFORMS = {
    "darwin-aarch64": ("lmx_macos_silicon.tar.gz", "./bin/lmx"),
    "darwin-x86_64": ("lmx_macos.tar.gz", "./bin/lmx"),
    "linux-x86_64": ("lmx_linux.tar.gz", "./bin/lmx"),
    "windows-x86_64": ("lmx_windows.tar.gz", "./bin/lmx.cmd"),
}


def build_entry(version, checksums):
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError("version must be X.Y.Z for an existing stable release")
    digests = {}
    for line in checksums.splitlines():
        if not line.strip():
            continue
        parts = line.split(maxsplit=1)
        if len(parts) != 2 or not re.fullmatch(r"[a-fA-F0-9]{64}", parts[0]):
            raise ValueError("invalid SHA256SUMS line")
        name = parts[1].lstrip("*")
        if name in digests:
            raise ValueError(f"duplicate checksum for {name}")
        digests[name] = parts[0].lower()
    binary = {
        platform: {
            "archive": f"{REPOSITORY}/releases/download/v{version}/{archive}",
            "sha256": digests[archive],
            "cmd": command,
            "args": ["acp"],
        }
        for platform, (archive, command) in PLATFORMS.items()
        if archive in digests
    }
    if not binary:
        raise ValueError("SHA256SUMS contains no supported lmx release archives")
    return {
        "id": "lemieux",
        "name": "Lemieux",
        "version": version,
        "description": "Open-source coding agent with a native Elixir runtime",
        "repository": REPOSITORY,
        "website": "https://hexdocs.pm/lemieux/acp.html",
        "license": "Apache-2.0",
        "license_url": f"{REPOSITORY}/blob/v{version}/LICENSE",
        "distribution": {"binary": binary},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--checksums", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        entry = build_entry(args.version, args.checksums.read_text())
    except ValueError as error:
        parser.error(str(error))
    destination = args.output / entry["id"]
    destination.mkdir(parents=True, exist_ok=True)
    (destination / "agent.json").write_text(json.dumps(entry, indent=2) + "\n")
    icon = Path(__file__).resolve().parent.parent / "priv" / "acp" / "icon.svg"
    shutil.copyfile(icon, destination / "icon.svg")
    print(destination)


if __name__ == "__main__":
    main()
