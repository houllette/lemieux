"""Install an lmx release for the current user after verifying it; never runs what it downloads.

Network installs download SHA256SUMS and its Ed25519 signature from the
release, check the signature against the key pinned below, then check every
downloaded file against those signed checksums. Anything missing or wrong
stops the installation before a file is written. A local archive is checked
against the SHA256SUMS you supply, and its signature too when you pass
--signature.

This file must stay parseable by Python 3.6 so that old interpreters reach
the version check below instead of failing with a SyntaxError.
"""
import sys

if sys.version_info < (3, 8):
    sys.exit("lmx's installer needs Python 3.8 or newer (found %d.%d). Install a newer Python 3 "
             "(for example your distribution's python3.11 package) and run this installer with it."
             % sys.version_info[:2])

import argparse
import base64
import binascii
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import secrets
import shlex
import socket
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

# The public half of the Ed25519 key the maintainer signs releases with, kept
# offline. `mix lmx.release.keygen` rewrites this line and
# dist/lmx/release-signing.pub together; a test checks they agree. While it is
# UNSET the installer refuses network installs: it could not tell a genuine
# release from one uploaded by someone else.
RELEASE_PUBLIC_KEY = "X7aGNLOgOV+bz13CuG4x4AVnhKmsPIH8eYvBrajsiG8="

ORIGIN = "https://github.com/houllette/lemieux/releases"
GUIDE = "https://github.com/houllette/lemieux/blob/main/docs/getting-started.md"
TARGETS = {("Darwin", "arm64"): "macos_silicon", ("Darwin", "x86_64"): "macos",
           ("Linux", "x86_64"): "linux"}
LIMIT = 150_000_000
SMALL = 100_000
# A download fails when the connection goes quiet for IDLE seconds, or runs
# past DEADLINE in total. One 120-second cap used to fail ordinary slow links
# (a 25 MB archive needs 215 KB/s) with the same message as an oversized file.
IDLE = 30
DEADLINE = 1800
# How long the installer waits for an update or another install to release the
# installation's lock: as long as the launcher waits, longer than the
# updater's two-minute download deadline.
LOCK_WAIT = 150
# The CA bundles OTP's public_key reads on Linux; lmx has no other trust store.
CA_BUNDLES = ("/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt",
              "/etc/ssl/ca-bundle.pem", "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
              "/etc/ssl/cert.pem")
NOTICES = ("LICENSE", "NOTICE", "THIRD_PARTY_NOTICES")
SUPPORTED = ("lmx release builds cover macOS (Apple Silicon and Intel) and x86-64 Linux with glibc 2.34 "
             "or newer (Ubuntu 22.04+, Debian 12+, Fedora, RHEL 9+, openSUSE, Amazon Linux 2023).")
SOURCE = "use the source checkout: see docs/getting-started.md (" + GUIDE + ")"
UNSIGNED = ("this installer has no release-signing key (RELEASE_PUBLIC_KEY is UNSET), so it cannot "
            "verify a download and refuses network installs. Install a local archive with "
            "--checksums SHA256SUMS instead, or " + SOURCE + ".")


# Ed25519 signature verification (RFC 8032, section 5.1.7) in plain Python, so
# installing needs nothing beyond the standard library. Verification only:
# signing happens offline with the maintainer's key.
_P = 2 ** 255 - 19
_L = 2 ** 252 + 27742317777372353535851937790883648493
_D = -121665 * pow(121666, _P - 2, _P) % _P
_ROOT_MINUS_ONE = pow(2, (_P - 1) // 4, _P)


def _add(a, b):
    # Extended homogeneous coordinates; RFC 8032, section 5.1.4.
    x1, y1, z1, t1 = a
    x2, y2, z2, t2 = b
    pa = (y1 - x1) * (y2 - x2) % _P
    pb = (y1 + x1) * (y2 + x2) % _P
    pc = 2 * t1 * t2 * _D % _P
    pd = 2 * z1 * z2 % _P
    e, f, g, h = pb - pa, pd - pc, pd + pc, pb + pa
    return (e * f % _P, g * h % _P, f * g % _P, e * h % _P)


def _multiply(scalar, point):
    result = (0, 1, 1, 0)
    while scalar:
        if scalar & 1:
            result = _add(result, point)
        point = _add(point, point)
        scalar >>= 1
    return result


def _same(a, b):
    return (a[0] * b[2] - b[0] * a[2]) % _P == 0 and (a[1] * b[2] - b[1] * a[2]) % _P == 0


def _decode_point(encoded):
    y = int.from_bytes(encoded, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    if y >= _P:
        return None
    square = (y * y - 1) * pow(_D * y * y + 1, _P - 2, _P) % _P
    if square == 0:
        return None if sign else (0, y, 1, 0)
    x = pow(square, (_P + 3) // 8, _P)
    if (x * x - square) % _P:
        x = x * _ROOT_MINUS_ONE % _P
    if (x * x - square) % _P:
        return None
    if (x & 1) != sign:
        x = _P - x
    return (x, y, 1, x * y % _P)


_BASE = _decode_point(bytes.fromhex("58" + "66" * 31))


def ed25519_verify(public_key, message, signature):
    """Whether `signature` is `public_key`'s Ed25519 signature over `message` (all bytes)."""
    if len(public_key) != 32 or len(signature) != 64:
        return False
    point = _decode_point(public_key)
    commitment = _decode_point(signature[:32])
    scalar = int.from_bytes(signature[32:], "little")
    if point is None or commitment is None or scalar >= _L:
        return False
    digest = hashlib.sha512(signature[:32] + public_key + message).digest()
    challenge = int.from_bytes(digest, "little") % _L
    return _same(_multiply(scalar, _BASE), _add(commitment, _multiply(challenge, point)))


def release_key():
    """The pinned public key as bytes, or None while it is UNSET."""
    if RELEASE_PUBLIC_KEY == "UNSET":
        return None
    try:
        key = base64.b64decode(RELEASE_PUBLIC_KEY, validate=True)
    except (binascii.Error, ValueError):
        key = b""
    if len(key) != 32:
        raise ValueError("this installer's RELEASE_PUBLIC_KEY is not an Ed25519 public key")
    return key


def read_signature(path):
    """Decodes a .sig file: the padded base64 of a 64-byte Ed25519 signature."""
    data = path.read_bytes()
    try:
        signature = base64.b64decode(data.strip(), validate=True) if len(data) <= 1024 else b""
    except (binascii.Error, ValueError):
        signature = b""
    if len(signature) != 64:
        raise ValueError(f"{path.name} is not an Ed25519 signature file")
    return signature


def verify_signature(path, signature_path, key):
    if not ed25519_verify(key, path.read_bytes(), read_signature(signature_path)):
        raise ValueError(f"{path.name} does not match {signature_path.name}: it was not signed with lmx's "
                         "release key, or it was changed after signing. Nothing was installed.")


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def platform_error(system, machine):
    if system == "Linux" and machine in ("aarch64", "arm64"):
        return "there is no Linux arm64 build yet; " + SOURCE + "."
    if system == "Windows" or system.startswith(("CYGWIN", "MINGW", "MSYS")):
        return ("this installer is for macOS and Linux. On Windows (experimental, needs Git for Windows' "
                "bash), unpack lmx_windows.tar.gz and run bin\\lmx.cmd; under WSL2, run this installer "
                "inside WSL to get the Linux build.")
    return f"{system} {machine} has no lmx release build. {SUPPORTED} Elsewhere, {SOURCE}."


def gnu_libc():
    """The C library's version, such as "glibc 2.39"; None where it is not glibc."""
    try:
        return os.confstr("CS_GNU_LIBC_VERSION")
    except (AttributeError, ValueError, OSError):  # musl has no such name, or raises EINVAL
        return None


def linux_preflight(libc):
    """Refuses Linux systems the release cannot start on, before anything is downloaded or written.

    The Linux build bundles its own OpenSSL and terminal handling, so it needs only
    glibc's libc, libm and libgcc_s; its runtime and TUI library use glibc 2.34
    symbols. The check reads the C library's version instead of asking the system
    loader about the archive's files, which keeps the promise main() prints:
    nothing from the archive is executed.
    """
    if not libc or not libc.startswith("glibc "):
        raise ValueError("this Linux system does not use glibc; musl distributions such as Alpine are not "
                         f"supported. {SUPPORTED} Elsewhere, {SOURCE}.")
    try:
        found = tuple(int(part) for part in libc.split()[1].split(".")[:2])
    except (IndexError, ValueError):
        found = (0, 0)
    if found < (2, 34):
        raise ValueError(f"lmx's Linux build needs glibc 2.34 or newer; this system has {libc}. "
                         f"{SUPPORTED} Elsewhere, {SOURCE}.")


def ca_warning(paths=CA_BUNDLES):
    """A warning when Linux has no CA bundle: every HTTPS call lmx makes would then fail."""
    if not any(os.path.isfile(path) for path in paths):
        return "warning: no CA certificates found; install ca-certificates or lmx cannot reach HTTPS providers"
    return None


def root_refusal(prefix_given, euid=None, environ=None):
    """Explains why a root install needs an explicit --prefix; None when the install may go ahead.

    Installations are per user: the tree is private to its owner (0700), and only
    that owner can run it or let it update itself. Run through sudo, the default
    prefix would make an installation nobody else can use.
    """
    if euid is None:
        euid = os.geteuid() if hasattr(os, "geteuid") else -1
    if environ is None:
        environ = os.environ
    if euid != 0 or prefix_given:
        return None
    user = environ.get("SUDO_USER")
    rerun = (f"Run the installer again without sudo, as {user}." if user else
             "Run it as the user who will run lmx.")
    return ("lmx installs per user, and an installation made as root can only be run and updated by root. "
            + rerun + " If root itself will run lmx (for example in a container), pass --prefix explicitly.")


def stable_version(value):
    return isinstance(value, str) and re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", value) is not None


def download(url, destination, limit=LIMIT, missing=None):
    name = url.rsplit("/", 1)[-1]
    request = urllib.request.Request(url, headers={"User-Agent": "lmx-installer"})
    started = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=IDLE) as source, destination.open("xb") as output:
            total = 0
            while True:
                data = source.read(64 * 1024)
                if not data:
                    break
                total += len(data)
                if total > limit:
                    raise ValueError(f"{name} is larger than {limit:,} bytes; refusing to continue")
                if time.monotonic() - started > DEADLINE:
                    raise ValueError(f"downloading {name} took longer than {DEADLINE // 60} minutes; "
                                     "check the connection and run the installer again")
                output.write(data)
    except urllib.error.HTTPError as error:
        if error.fp is not None:
            error.close()
        if error.code == 404 and missing:
            raise ValueError(missing) from None
        raise ValueError(f"downloading {name} failed: HTTP {error.code}") from None
    except socket.timeout:
        raise ValueError(f"downloading {name} stalled: no data for {IDLE} seconds; "
                         "check the connection and run the installer again") from None
    except urllib.error.URLError as error:
        raise ValueError(f"could not download {name}: {error.reason}") from None


def checksums(path):
    result = {}
    for line in path.read_text().splitlines():
        parts = line.split(maxsplit=1)
        if len(parts) != 2:
            raise ValueError("invalid checksum entry")
        digest, name = parts
        name = name.lstrip("*")
        if name in result or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
            raise ValueError("invalid or duplicate checksum entry")
        result[name] = digest
    return result


def extract(archive, destination):
    with tarfile.open(archive, "r:gz") as bundle:
        members = []
        names = set()
        total = 0
        for item in bundle:
            name = item.name.rstrip("/")
            parts = name.split("/")
            if (not (item.isfile() or item.isdir()) or item.name.startswith("/") or
                any(p in ("", ".", "..") for p in parts) or any(c in item.name for c in "\\:\0") or
                name in names or item.size < 0 or item.size > 200_000_000 or item.mode & 0o6002):
                raise ValueError("unsafe release archive")
            names.add(name)
            members.append(item)
            total += item.size
            if len(members) > 20_000 or total > 1_000_000_000:
                raise ValueError("oversized release archive")
        files = {item.name.rstrip("/") for item in members if item.isfile()}
        if any(any(parent.as_posix() in files for parent in Path(item.name).parents)
               for item in members):
            raise ValueError("unsafe release archive")
        # Every entry, links included, was vetted above and the destination is
        # fresh. The "data" filter (Python 3.12+, and security releases of
        # 3.8-3.11) re-checks the same rules and avoids the deprecation warning
        # for extracting without one.
        if hasattr(tarfile, "data_filter"):
            bundle.extractall(destination, members=members, filter="data")
        else:
            bundle.extractall(destination, members=members)


def reclaim(path, recovery):
    """Removes the lock at `path` when the process it records is gone.

    Shares the updater's recovery guard. Only a recorded dead owner is
    eligible; empty locks, permission errors and a competing recovery fail
    closed.
    """
    try:
        os.link(path, recovery)
    except (FileNotFoundError, FileExistsError):
        pass
    else:
        try:
            pid = recovery.read_text()
            if pid.isascii() and pid.isdigit() and int(pid) > 0:
                try:
                    os.kill(int(pid), 0)
                except ProcessLookupError:
                    if path.stat().st_ino == recovery.stat().st_ino:
                        path.unlink()
                except PermissionError:
                    pass
        finally:
            recovery.unlink()


@contextmanager
def lock(home, wait=None):
    """Holds the installation's `.update-lock`, waiting up to `wait` seconds (LOCK_WAIT) for its holder.

    A running terminal UI holds the lock while it downloads and stages an
    automatic update (up to about two minutes), and every launch holds it for
    a moment. The installer used to fail at once with "[Errno 17] File
    exists"; it now waits as the launcher does, then says what is going on.
    """
    wait = LOCK_WAIT if wait is None else wait
    path = home / ".update-lock"
    recovery = home / ".update-lock.recovery"
    deadline = time.monotonic() + wait
    attempts = 0
    while True:
        reclaim(path, recovery)
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            break
        except FileExistsError:
            attempts += 1
            if time.monotonic() >= deadline:
                raise ValueError("installation is busy: an lmx update or another install is running. Try again "
                                 "when it completes; if none is running, see 'If an install or update was "
                                 "interrupted' in docs/support.md") from None
            # A launch holds the lock for a moment; say something only when
            # the wait is longer than that.
            if attempts == 2:
                print(f"install.py: an lmx update or another install is using {home}; waiting up to "
                      f"{wait:g} seconds for it to finish", file=sys.stderr)
            time.sleep(min(1, max(0, deadline - time.monotonic())))
    try:
        os.write(fd, str(os.getpid()).encode())
        yield
    finally:
        os.close(fd)
        path.unlink()


def canonical_mode(mode):
    """The mode a regular file with archive mode `mode` gets from every extractor of an lmx archive.

    Python's "data" filter (used by extract() where it exists) keeps 0o755 of
    the mode, adds owner read and write, and drops group and other execute
    when the owner has none; the updater's :erl_tar, and Python without the
    filter, keep the archive's mode. Sixteen files arrive from their Hex
    packages as 0664, and comparing mode & 0o777 made --replace refuse a
    version directory the updater had staged ("existing version directory
    differs from verified archive"), and one this installer had made under a
    Python without the filter. Release builds now pack modes already in this
    form (Lmx.Release.normalize_modes/1); Lmx.Update.Payload.canonical_mode/1
    is the updater's copy of this rule.
    """
    kept = mode & 0o755
    if not kept & 0o100:
        kept &= ~0o111
    return kept | 0o600


def payload(root):
    if root.is_symlink() or not root.is_dir():
        raise ValueError("unsafe staged directory")
    entries = []
    for directory, folders, files in os.walk(root, followlinks=False):
        for name in sorted(folders + files):
            path = Path(directory) / name
            relative = path.relative_to(root).as_posix()
            if path.is_symlink():
                raise ValueError("unsafe staged directory")
            if path.is_dir():
                entries.append((relative, "directory"))
            elif path.is_file():
                entries.append((relative, hashlib.sha256(path.read_bytes()).hexdigest(),
                                canonical_mode(path.stat().st_mode)))
            else:
                raise ValueError("unsafe staged directory")
    return sorted(entries)


def select(home, destination):
    temporary = home / (".current-" + secrets.token_hex(8))
    try:
        temporary.symlink_to(destination)
        os.replace(temporary, home / "current")
    finally:
        temporary.unlink(missing_ok=True)


def current_target():
    system, machine = platform.system(), platform.machine().lower()
    target = TARGETS.get((system, machine))
    if target is None:
        raise ValueError(platform_error(system, machine))
    if target == "linux":
        linux_preflight(gnu_libc())
    return target


def wrapper(home):
    """The launcher this installer writes at PREFIX/bin/lmx, and what marks an installation as its own."""
    return ("#!/bin/sh\nset -eu\nexport LMX_INSTALL_HOME=" + shlex.quote(str(home)) +
            "\nexec \"$LMX_INSTALL_HOME/current/bin/lmx\" \"$@\"\n")


def managed(launcher, home):
    """Whether `launcher` is the wrapper this installer wrote for `home`, so upgrading it needs no --replace.

    Only an exact match counts. A wrapper written for another prefix, a
    symlink, or any other executable is somebody else's, or an installation
    whose ownership is in doubt, and --replace is the explicit choice to
    install over it. Upgrading used to need --replace too, which read as
    permission to overwrite an unrelated program rather than as the normal way
    to update (issue #5).
    """
    try:
        if launcher.is_symlink() or not launcher.is_file() or launcher.stat().st_size > 4096:
            return False
        return launcher.read_text() == wrapper(home)
    except (OSError, UnicodeDecodeError):
        return False


def install(archive, sums, prefix, replace=False):
    """Installs `archive` after checking it against `sums`; the caller vouches for `sums`.

    The whole archive becomes the version directory, so its LICENSE, NOTICE and
    THIRD_PARTY_NOTICES stay with the runtime they describe. An existing
    PREFIX/bin/lmx that this installer wrote is upgraded in place; any other
    is left alone unless `replace` says to install over it.
    """
    target = current_target()
    name = f"lmx_{target}.tar.gz"
    if archive.name != name:
        raise ValueError(f"expected {name}")
    if archive.stat().st_size > LIMIT:
        raise ValueError("oversized download")
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if checksums(sums).get(name) != digest:
        raise ValueError("archive checksum does not match SHA256SUMS")
    prefix = prefix.expanduser().resolve()
    home = prefix / "share/lmx"
    launcher = prefix / "bin/lmx"
    if os.path.lexists(launcher) and not replace and not managed(launcher, home):
        raise ValueError(f"{launcher} exists and is not an lmx launcher this installer wrote; "
                         "use --replace to install over it")
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    with lock(home), tempfile.TemporaryDirectory(prefix=".stage-", dir=home) as scratch:
        scratch = Path(scratch)
        extract(archive, scratch)
        metadata = list(scratch.glob("releases/*/release.json"))
        if len(metadata) != 1:
            raise ValueError("expected one release identity")
        info = json.loads(metadata[0].read_text())
        version = info["version"]
        if (info["target"] != target or metadata[0].parent.name != version or
            not (scratch / "bin/lmx").is_file() or not (scratch / f"releases/{version}/lmx.rel").is_file()):
            raise ValueError("release identity does not match archive")
        identity = info["build_id"]
        if len(identity) != 64 or any(c not in "0123456789abcdef" for c in identity):
            raise ValueError("invalid build identity")
        if not stable_version(version):
            raise ValueError("invalid release version")
        versions = home / "versions"
        versions.mkdir(exist_ok=True)
        if versions.is_symlink():
            raise ValueError("versions must be a real directory")
        destination = versions / f"{version}-{identity[:12]}"
        if os.path.lexists(destination):
            if payload(scratch) != payload(destination):
                raise ValueError("existing version directory differs from verified archive")
        else:
            scratch.rename(destination)
        # Keep the prior full release for rollback; sessions live outside this tree.
        launcher.parent.mkdir(parents=True, exist_ok=True)
        current = home / "current"
        if os.path.lexists(current) and not current.is_symlink():
            raise ValueError("current must be a release symlink")
        previous = os.readlink(current) if current.is_symlink() else None
        fd, temporary = tempfile.mkstemp(prefix=".lmx-", dir=launcher.parent)
        switched = False
        try:
            with os.fdopen(fd, "w") as output:
                output.write(wrapper(home))
            os.chmod(temporary, 0o755)
            select(home, destination)
            switched = True
            os.replace(temporary, launcher)
        except BaseException:
            if switched:
                if previous is None:
                    current.unlink()
                else:
                    select(home, previous)
            raise
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    return launcher


def installer_listed(sums):
    """Requires that signed checksums list this very installer, so a mismatched bootstrap stops early."""
    if checksums(sums).get("install.py") != sha256(Path(__file__)):
        raise ValueError("this install.py is not the one listed in the signed SHA256SUMS; "
                         "download install.sh again and rerun it")


def network_install(release, prefix, replace, bootstrap=None):
    """Downloads, verifies and installs a release; `bootstrap` holds install.sh's signed SHA256SUMS."""
    target = current_target()
    key = release_key()
    if key is None:
        raise ValueError(UNSIGNED)
    if release != "latest" and not stable_version(release):
        raise ValueError("invalid release version")
    if bootstrap:
        verify_signature(bootstrap[0], bootstrap[1], key)
        installer_listed(bootstrap[0])
    base = ORIGIN + ("/latest/download" if release == "latest" else f"/download/v{release}")
    with tempfile.TemporaryDirectory(prefix="lmx-download-") as scratch:
        scratch = Path(scratch)
        sums, signature = scratch / "SHA256SUMS", scratch / "SHA256SUMS.sig"
        if bootstrap and release == "latest":
            # install.sh fetched these from the latest release moments ago.
            sums.write_bytes(bootstrap[0].read_bytes())
            signature.write_bytes(bootstrap[1].read_bytes())
        else:
            download(base + "/SHA256SUMS", sums, SMALL,
                     missing=f"no published lmx release was found at {base}")
            download(base + "/SHA256SUMS.sig", signature, 1_000,
                     missing="this release has no SHA256SUMS.sig, so it cannot be verified; "
                             "refusing to install an unsigned release")
        try:
            verify_signature(sums, signature, key)
        except ValueError as error:
            if release == "latest":
                raise
            # This installer pins the key of the latest release. One signed
            # before the key changed verifies only with the key it was
            # signed with, which its own install.py pins.
            raise ValueError(f"{error} If v{release} was released before lmx's release-signing key changed, "
                             f"install it with its own installer: download {ORIGIN}/download/v{release}/install.py "
                             f"and run it with --release {release} (see docs/releases.md, "
                             "Recovery and rollback).") from None
        table = checksums(sums)
        manifest = scratch / "update.json"
        download(base + "/update.json", manifest, SMALL)
        if table.get("update.json") != sha256(manifest):
            raise ValueError("update.json does not match the signed SHA256SUMS (a release may have been "
                             "published while installing); run the installer again")
        version = json.loads(manifest.read_text())["version"]
        if not stable_version(version):
            raise ValueError("invalid manifest version")
        if release != "latest" and version != release:
            raise ValueError("manifest version mismatch")
        archive = scratch / f"lmx_{target}.tar.gz"
        download(ORIGIN + f"/download/v{version}/" + archive.name, archive)
        return install(archive, sums, prefix, replace)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("archive", nargs="?", type=Path, help="a downloaded lmx_TARGET.tar.gz")
    parser.add_argument("--checksums", type=Path, help="SHA256SUMS for the archive or release")
    parser.add_argument("--signature", type=Path, help="SHA256SUMS.sig, checked against the pinned release key")
    parser.add_argument("--release", default="latest", help="stable release version, or latest")
    parser.add_argument("--prefix", type=Path, help="installation prefix (default: ~/.local)")
    parser.add_argument("--replace", action="store_true")
    args = parser.parse_args(argv)
    try:
        refusal = root_refusal(args.prefix is not None)
        if refusal:
            raise ValueError(refusal)
        prefix = args.prefix if args.prefix is not None else Path.home() / ".local"
        # Unsupported systems are refused here, before any warning or download.
        if current_target() == "linux":
            warning = ca_warning()
            if warning:
                print(warning, file=sys.stderr)
        if args.archive:
            if not args.checksums:
                raise ValueError("local installation requires --checksums SHA256SUMS")
            if args.signature:
                key = release_key()
                if key is None:
                    raise ValueError("--signature cannot be checked: this installer has no release-signing "
                                     "key (RELEASE_PUBLIC_KEY is UNSET)")
                verify_signature(args.checksums, args.signature, key)
                verified = "Signature and checksum verified: the SHA256SUMS you supplied is signed with lmx's release key, and the archive matches it."
            else:
                print("warning: no signature was checked. The archive is compared with the SHA256SUMS you "
                      "supplied, but nothing shows that file came from lmx's maintainers; pass "
                      "--signature SHA256SUMS.sig to check it.", file=sys.stderr)
                verified = "Checksum verified against the SHA256SUMS you supplied; no signature was checked, so its origin is unverified."
            launcher = install(args.archive, args.checksums, prefix, args.replace)
        else:
            if bool(args.checksums) != bool(args.signature):
                raise ValueError("--checksums and --signature go together when installing from the network")
            bootstrap = (args.checksums, args.signature) if args.checksums else None
            launcher = network_install(args.release, prefix, args.replace, bootstrap)
            verified = "Signature and checksum verified: SHA256SUMS is signed with lmx's release key, and the archive matches it."
        print(f"Installed {launcher}. Add {launcher.parent} to PATH, then run lmx --version.")
        # Not "nothing downloaded": through install.sh, this script was itself
        # downloaded and is running. What it never runs is the archive's content.
        print(verified + " Nothing from the archive was executed.")
        current = launcher.parent.parent / "share/lmx/current"
        present = [name for name in NOTICES if (current / name).is_file()]
        if present:
            print("Licenses and notices: " + ", ".join(str(current / name) for name in present))
        if hasattr(os, "geteuid") and os.geteuid() == 0:
            print("note: this installation belongs to root; other users, including a later Dockerfile USER, "
                  "cannot run or update it. Install as that user instead.", file=sys.stderr)
    except (OSError, ValueError, KeyError, tarfile.TarError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
