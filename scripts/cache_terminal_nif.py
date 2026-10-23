#!/usr/bin/env python3
"""Fill a CI-owned Rustler cache without httpc's response-header limit.

GitHub's release redirect exceeded OTP's 10 KiB response-header limit on two
Linux example attempts. Curl keeps TLS verification; the Hex package's exact
checksum is checked here and Rustler checks it again before loading the NIF.
This changes download transport only, never the selected native artifact.
"""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile


def select(contents, nif_version, system, machine, abi=None):
    architectures = {"arm64": "aarch64", "aarch64": "aarch64", "x86_64": "x86_64", "AMD64": "x86_64"}
    arch = architectures[machine]
    if system == "Darwin":
        target = arch + "-apple-darwin"
    elif system == "Linux":
        target = arch + "-unknown-linux-" + ("musl" if abi == "musl" else "gnu")
    else:
        raise ValueError("unsupported CI native platform")
    limit = tuple(map(int, nif_version.split(".")))
    entries = re.findall(r'"((?:lib)?ex_ratatui-v([0-9.]+)-nif-([0-9.]+)-[^"/]+\.so\.tar\.gz)"\s*=>\s*"sha256:([a-f0-9]{64})"', contents)
    compatible = [x for x in entries if x[0].endswith(target + ".so.tar.gz") and tuple(map(int, x[2].split("."))) <= limit]
    if not compatible or len({x[1] for x in compatible}) != 1:
        raise ValueError("missing or ambiguous compatible terminal NIF checksum")
    name, version, _, checksum = max(compatible, key=lambda x: tuple(map(int, x[2].split("."))))
    return name if name.startswith("lib") else "lib" + name, version, checksum


def download(url, destination):
    subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error",
                    "--retry", "3", "--connect-timeout", "15", "--max-time", "120",
                    "--max-filesize", "104857600", "--proto", "=https", "--proto-redir", "=https",
                    "--output", str(destination), url], check=True)


def verified(path, checksum):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest() == checksum


def cache(directory, selection, fetch=download):
    name, version, checksum = selection
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    destination = directory / name
    if destination.exists():
        if not verified(destination, checksum):
            raise ValueError("existing CI cache artifact has the wrong checksum")
        return destination
    descriptor, temporary = tempfile.mkstemp(prefix="download-", dir=directory)
    os.close(descriptor)
    temporary = Path(temporary)
    try:
        fetch(f"https://github.com/mcass19/ex_ratatui/releases/download/v{version}/{name}", temporary)
        if not verified(temporary, checksum):
            raise ValueError("downloaded terminal NIF has the wrong checksum")
        temporary.replace(destination)
        return destination
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("cache", type=Path)
    parser.add_argument("--nif-version", required=True)
    args = parser.parse_args()
    checksum = args.package / "checksum-Elixir.ExRatatui.Native.exs"
    if checksum.is_file():
        selection = select(checksum.read_text(), args.nif_version, platform.system(), platform.machine(), os.environ.get("TARGET_ABI"))
        print("Verified CI terminal NIF: " + cache(args.cache, selection).name)


if __name__ == "__main__":
    main()
