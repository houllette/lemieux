"""Release signing and platform checks in scripts/install.py, without network access or a real key.

Signing keys here are throwaway: the RFC 8032 test keys, keys derived from
fixed test seeds, and the fixture under test/fixtures/install, which
`mix lmx.release.sign` signed with a key that was deleted afterwards.

To regenerate that fixture, make a throwaway key outside any Git checkout
(the tasks refuse keys inside one): a file holding the base64 of the private
half of :crypto.generate_key(:eddsa, :ed25519). Then, from dist/lmx, run
`mix lmx.release.sign --private-key FILE --public-key PUBLIC SHA256SUMS
update.json` on the fixture files, write PUBLIC to signing-key.pub and delete
FILE. Never use keygen for this: it pins the key it makes.
"""
import ast
import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "test/fixtures/install"
INSTALLER = ROOT / "scripts/install.py"
spec = importlib.util.spec_from_file_location("lmx_install_signing", INSTALLER)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

# RFC 8032, section 7.1: TEST 1, TEST 2, TEST 3 and TEST SHA(abc).
RFC8032 = [
    ("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
     "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
     "",
     "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
     "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
    ("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
     "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
     "72",
     "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
     "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
    ("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
     "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
     "af82",
     "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac"
     "18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a"),
    ("833fe62409237b9d62ec77587520911e9a759cec1d19755b7da901b96dca3d42",
     "ec172b93ad5e563bf4932c70e1245034c35467ef2efd4d64ebf819683467e2bf",
     "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
     "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
     "dc2a4459e7369633a52b1bf277839a00201009a3efbf3ecb69bea2186c26b589"
     "09351fc9ac90b3ecfdfbc7c66431e0303dca179c138ac17ad9bef1177331a704"),
]
TARGET = installer.TARGETS.get((platform.system(), platform.machine().lower()))


def encode_point(point):
    x, y, z, _ = point
    inverse = pow(z, installer._P - 2, installer._P)
    x, y = x * inverse % installer._P, y * inverse % installer._P
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


def keypair(seed):
    """RFC 8032 section 5.1.5 key generation; test-only, like sign()."""
    digest = hashlib.sha512(seed).digest()
    scalar = int.from_bytes(digest[:32], "little") & ((1 << 254) - 8) | (1 << 254)
    return scalar, digest[32:], encode_point(installer._multiply(scalar, installer._BASE))


def sign(seed, message):
    """RFC 8032 section 5.1.6 signing, so tests can sign fresh releases without a key on disk."""
    scalar, prefix, public = keypair(seed)
    nonce = int.from_bytes(hashlib.sha512(prefix + message).digest(), "little") % installer._L
    commitment = encode_point(installer._multiply(nonce, installer._BASE))
    challenge = int.from_bytes(hashlib.sha512(commitment + public + message).digest(), "little") % installer._L
    return commitment + ((nonce + challenge * scalar) % installer._L).to_bytes(32, "little")


TEST_SEED = hashlib.sha256(b"lmx install.py test key").digest()
TEST_PUBLIC = base64.b64encode(keypair(TEST_SEED)[2]).decode()
OTHER_SEED = hashlib.sha256(b"someone else's key").digest()


def signature_file(path, seed=TEST_SEED):
    signature = path.with_name(path.name + ".sig")
    signature.write_text(base64.b64encode(sign(seed, path.read_bytes())).decode() + "\n")
    return signature


def build_archive(root, target, version="0.1.0", extra=None):
    archive = root / f"lmx_{target}.tar.gz"
    info = {"version": version, "target": target, "build_id": "a" * 64}
    files = {"bin/lmx": b"#!/bin/sh\nexit 99\n",
             f"releases/{version}/release.json": json.dumps(info).encode(),
             f"releases/{version}/lmx.rel": b"release"}
    files.update(extra or {})
    with tarfile.open(archive, "w:gz") as bundle:
        for name, data in files.items():
            item = tarfile.TarInfo(name)
            item.size = len(data)
            item.mode = 0o755 if name == "bin/lmx" else 0o644
            bundle.addfile(item, io.BytesIO(data))
    return archive


def fake_release(root, target, version="0.1.0", listed_installer=True):
    """A directory standing in for one GitHub release's assets."""
    release = root / "release"
    release.mkdir()
    archive = build_archive(release, target, version)
    manifest = release / "update.json"
    manifest.write_text(json.dumps({"schema_version": 1, "version": version, "targets": {}}) + "\n")
    names = [archive, manifest] + ([INSTALLER] if listed_installer else [])
    (release / "SHA256SUMS").write_text("".join(
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n" for path in names))
    signature_file(release / "SHA256SUMS")
    return release


@contextlib.contextmanager
def served(release, requested):
    """Replaces installer.download with copies out of `release`, recording each asset requested."""
    def download(url, destination, limit=installer.LIMIT, missing=None):
        name = url.rsplit("/", 1)[-1]
        requested.append(name)
        source = release / name
        if not source.is_file():
            raise ValueError(missing or f"downloading {name} failed: HTTP 404")
        destination.write_bytes(source.read_bytes())
    with patch.object(installer, "download", download):
        yield


def run_main(argv):
    """Runs installer.main in-process; returns (exit status, stdout, stderr)."""
    out, err = io.StringIO(), io.StringIO()
    status = 0
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            installer.main(argv)
        except SystemExit as exit:
            status = exit.code
    return status, out.getvalue(), err.getvalue()


class Ed25519Test(unittest.TestCase):
    def test_rfc8032_vectors_verify_and_any_change_fails(self):
        for secret, public, message, signature in RFC8032:
            public, message, signature = bytes.fromhex(public), bytes.fromhex(message), bytes.fromhex(signature)
            with self.subTest(public=public.hex()):
                self.assertTrue(installer.ed25519_verify(public, message, signature))
                self.assertFalse(installer.ed25519_verify(public, message + b"\0", signature))
                for index in (0, 31, 32, 63):
                    altered = bytearray(signature)
                    altered[index] ^= 1
                    self.assertFalse(installer.ed25519_verify(public, message, bytes(altered)))
                other = bytes.fromhex(RFC8032[0][1] if public.hex() != RFC8032[0][1] else RFC8032[1][1])
                self.assertFalse(installer.ed25519_verify(other, message, signature))

    def test_test_signer_reproduces_the_rfc8032_signatures(self):
        # The tests below sign with this helper; it must agree with the RFC.
        for secret, public, message, signature in RFC8032:
            seed = bytes.fromhex(secret)
            self.assertEqual(keypair(seed)[2].hex(), public)
            self.assertEqual(sign(seed, bytes.fromhex(message)).hex(), signature)

    def test_out_of_range_and_malformed_inputs_are_rejected(self):
        _, public, message, signature = RFC8032[1]
        public, message, signature = bytes.fromhex(public), bytes.fromhex(message), bytes.fromhex(signature)
        scalar = int.from_bytes(signature[32:], "little")
        # S + L is the same point but a non-canonical scalar (signature malleability).
        stretched = signature[:32] + (scalar + installer._L).to_bytes(32, "little")
        self.assertFalse(installer.ed25519_verify(public, message, stretched))
        # A y coordinate of p or more is not a canonical encoding.
        self.assertFalse(installer.ed25519_verify((installer._P + 1).to_bytes(32, "little"), message, signature))
        self.assertFalse(installer.ed25519_verify(public[:31], message, signature))
        self.assertFalse(installer.ed25519_verify(public, message, signature[:63]))

    def test_the_mix_task_fixture_verifies_here_and_tampering_does_not(self):
        key = base64.b64decode((FIXTURES / "signing-key.pub").read_text().strip())
        for name in ("SHA256SUMS", "update.json"):
            body = (FIXTURES / name).read_bytes()
            signature = installer.read_signature(FIXTURES / (name + ".sig"))
            self.assertTrue(installer.ed25519_verify(key, body, signature), name)
            tampered = body[:10] + bytes([body[10] ^ 1]) + body[11:]
            self.assertFalse(installer.ed25519_verify(key, tampered, signature), name)

    def test_signature_files_must_be_padded_base64_of_64_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "SHA256SUMS.sig"
            for text in ("", "not base64!", base64.b64encode(b"\1" * 63).decode(), "A" * 5000):
                path.write_text(text)
                with self.assertRaisesRegex(ValueError, "not an Ed25519 signature"):
                    installer.read_signature(path)
            path.write_text(base64.b64encode(b"\1" * 64).decode() + "\n")
            self.assertEqual(installer.read_signature(path), b"\1" * 64)


class PinnedKeyTest(unittest.TestCase):
    def test_installer_and_release_host_pin_the_same_key(self):
        lines = [line for line in INSTALLER.read_text().splitlines() if line.startswith("RELEASE_PUBLIC_KEY")]
        self.assertEqual(len(lines), 1, "exactly one RELEASE_PUBLIC_KEY line, which keygen rewrites")
        pinned = (ROOT / "dist/lmx/release-signing.pub").read_text().strip()
        self.assertEqual(lines[0], f'RELEASE_PUBLIC_KEY = "{pinned}"')
        self.assertEqual(installer.RELEASE_PUBLIC_KEY, pinned)
        if pinned != "UNSET":
            self.assertEqual(len(base64.b64decode(pinned, validate=True)), 32)

    def test_an_unset_key_refuses_network_installs_before_downloading(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(installer, "RELEASE_PUBLIC_KEY", "UNSET"), \
                patch.object(installer, "current_target", return_value="linux"), \
                patch.object(installer, "download", side_effect=AssertionError("must not download")):
            status, _, stderr = run_main(["--prefix", str(Path(directory) / "prefix")])
            self.assertEqual(status, 2)
            self.assertIn("RELEASE_PUBLIC_KEY is UNSET", stderr)
            self.assertIn("refuses network installs", stderr)
            self.assertFalse((Path(directory) / "prefix").exists())


@unittest.skipIf(TARGET is None, "Unix installer only")
class NetworkInstallTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.prefix = self.root / "prefix"
        self.patches = [patch.object(installer, "RELEASE_PUBLIC_KEY", TEST_PUBLIC),
                        patch.object(installer, "current_target", return_value=TARGET)]
        for active in self.patches:
            active.start()

    def tearDown(self):
        for active in self.patches:
            active.stop()
        self.directory.cleanup()

    def test_a_signed_release_installs(self):
        release, requested = fake_release(self.root, TARGET), []
        with served(release, requested):
            launcher = installer.network_install("latest", self.prefix, False)
        self.assertEqual(launcher, self.prefix.resolve() / "bin/lmx")
        self.assertEqual(requested, ["SHA256SUMS", "SHA256SUMS.sig", "update.json", f"lmx_{TARGET}.tar.gz"])
        self.assertTrue((self.prefix / "share/lmx/current/bin/lmx").is_file())

    def test_a_tampered_sha256sums_is_rejected_before_the_archive_is_fetched(self):
        release, requested = fake_release(self.root, TARGET), []
        sums = release / "SHA256SUMS"
        sums.write_text(sums.read_text().replace(sums.read_text()[:64], "0" * 64, 1))
        with served(release, requested), self.assertRaisesRegex(ValueError, "does not match SHA256SUMS.sig"):
            installer.network_install("latest", self.prefix, False)
        self.assertEqual(requested, ["SHA256SUMS", "SHA256SUMS.sig"])
        self.assertFalse(self.prefix.exists())

    def test_a_signature_by_another_key_is_rejected(self):
        release, requested = fake_release(self.root, TARGET), []
        signature_file(release / "SHA256SUMS", OTHER_SEED)
        with served(release, requested), self.assertRaisesRegex(ValueError, "not signed with lmx's release key"):
            installer.network_install("latest", self.prefix, False)
        self.assertFalse(self.prefix.exists())

    def test_an_unsigned_release_is_refused(self):
        release, requested = fake_release(self.root, TARGET), []
        (release / "SHA256SUMS.sig").unlink()
        with served(release, requested), self.assertRaisesRegex(ValueError, "refusing to install an unsigned release"):
            installer.network_install("latest", self.prefix, False)
        self.assertFalse(self.prefix.exists())

    def test_the_manifest_must_be_the_one_the_signature_covers(self):
        release, requested = fake_release(self.root, TARGET), []
        (release / "update.json").write_text(json.dumps({"schema_version": 1, "version": "0.1.0", "targets": {}}))
        with served(release, requested), self.assertRaisesRegex(ValueError, "update.json does not match the signed"):
            installer.network_install("latest", self.prefix, False)
        self.assertNotIn(f"lmx_{TARGET}.tar.gz", requested)

    def test_install_sh_bootstrap_files_are_reused_only_when_they_list_this_installer(self):
        release, requested = fake_release(self.root, TARGET), []
        bootstrap = (release / "SHA256SUMS", release / "SHA256SUMS.sig")
        with served(release, requested):
            installer.network_install("latest", self.prefix, False, bootstrap)
        self.assertEqual(requested, ["update.json", f"lmx_{TARGET}.tar.gz"])
        unlisted = self.root / "unlisted"
        unlisted.mkdir()
        release = fake_release(unlisted, TARGET, listed_installer=False)
        with served(release, []), self.assertRaisesRegex(ValueError, "not the one listed"):
            installer.network_install("latest", unlisted / "prefix", False,
                                      (release / "SHA256SUMS", release / "SHA256SUMS.sig"))


@unittest.skipIf(TARGET is None, "Unix installer only")
class LocalInstallTest(unittest.TestCase):
    def test_without_a_signature_the_installer_warns_and_claims_only_a_checksum(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            release = fake_release(root, TARGET)
            result = subprocess.run([sys.executable, str(INSTALLER), str(release / f"lmx_{TARGET}.tar.gz"),
                                     "--checksums", str(release / "SHA256SUMS"), "--prefix", str(root / "prefix")],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("warning: no signature was checked", result.stderr)
            self.assertIn("no signature was checked, so its origin is unverified", result.stdout)
            self.assertNotIn("Signature and checksum verified", result.stdout)
            self.assertNotIn("GitHub", result.stdout)

    def test_a_supplied_signature_is_checked_with_the_pinned_key(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            release = fake_release(root, TARGET)
            archive, sums, signature = (release / f"lmx_{TARGET}.tar.gz", release / "SHA256SUMS",
                                        release / "SHA256SUMS.sig")
            argv = [str(archive), "--checksums", str(sums), "--signature", str(signature)]
            with patch.object(installer, "RELEASE_PUBLIC_KEY", "UNSET"):
                status, _, stderr = run_main(argv + ["--prefix", str(root / "unset")])
            self.assertEqual(status, 2)
            self.assertIn("--signature cannot be checked", stderr)
            with patch.object(installer, "RELEASE_PUBLIC_KEY", TEST_PUBLIC):
                signature_file(sums, OTHER_SEED)
                status, _, stderr = run_main(argv + ["--prefix", str(root / "forged")])
                self.assertEqual(status, 2)
                self.assertIn("not signed with lmx's release key", stderr)
                self.assertFalse((root / "forged").exists())
                signature_file(sums)
                status, stdout, stderr = run_main(argv + ["--prefix", str(root / "signed")])
            self.assertEqual(status, 0, stderr)
            self.assertIn("Signature and checksum verified", stdout)
            self.assertNotIn("warning: no signature", stderr)

    def test_licenses_and_notices_stay_in_the_installed_tree_and_extraction_is_warning_free(self):
        notices = {"LICENSE": b"Apache License 2.0\n", "NOTICE": b"lmx\n",
                   "THIRD_PARTY_NOTICES": b"OTP, Elixir, dependencies\n"}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = build_archive(root, TARGET, extra=notices)
            sums = root / "SHA256SUMS"
            sums.write_text(f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}\n")
            # Python 3.12 and 3.13 warn when extractall has no filter.
            result = subprocess.run([sys.executable, "-W", "error::DeprecationWarning", str(INSTALLER),
                                     str(archive), "--checksums", str(sums), "--prefix", str(root / "prefix")],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            current = root / "prefix/share/lmx/current"
            for name, body in notices.items():
                self.assertEqual((current / name).read_bytes(), body)
            self.assertIn("THIRD_PARTY_NOTICES", result.stdout)


FAKE_CURL = """#!/bin/sh
# Serves "https://.../NAME" from $LMX_FAKE_RELEASE/NAME, like curl --fail -o FILE.
out=
url=
while [ $# -gt 0 ]; do
  case $1 in
    -o) out=$2; shift 2 ;;
    https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
echo "$url" >> "$LMX_FAKE_RELEASE.requests"
[ -f "$LMX_FAKE_RELEASE/${url##*/}" ] || { echo 'curl: (22) The requested URL returned error: 404' >&2; exit 22; }
cp "$LMX_FAKE_RELEASE/${url##*/}" "$out"
"""
FAKE_INSTALLER = "import json, os, sys\nopen(os.environ['LMX_FAKE_ARGS'], 'w').write(json.dumps(sys.argv[1:]))\n"


@unittest.skipIf(os.name == "nt", "POSIX shell bootstrap")
class BootstrapTest(unittest.TestCase):
    def bootstrap(self, root, shell="sh", edit=None, python=sys.executable):
        release = root / "release"
        release.mkdir()
        (release / "install.py").write_text(FAKE_INSTALLER)
        digest = hashlib.sha256(FAKE_INSTALLER.encode()).hexdigest()
        (release / "SHA256SUMS").write_text(f"{'a' * 64}  lmx_linux.tar.gz\n{digest}  install.py\n")
        signature_file(release / "SHA256SUMS")
        if edit:
            edit(release)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        (bin_dir / "curl").write_text(FAKE_CURL)
        (bin_dir / "curl").chmod(0o755)
        # The python3 found on PATH is this test's interpreter.
        (bin_dir / "python3").symlink_to(sys.executable)
        env = dict(os.environ, PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
                   LMX_FAKE_RELEASE=str(release), LMX_FAKE_ARGS=str(root / "args.json"))
        env.pop("LMX_PYTHON", None)
        if python:
            env["LMX_PYTHON"] = python
        result = subprocess.run([shell, str(ROOT / "scripts/install.sh"), "--prefix", str(root / "prefix")],
                                env=env, capture_output=True, text=True, timeout=60)
        requests = (root / "release.requests").read_text().split() if (root / "release.requests").exists() else []
        return result, [url.rsplit("/", 1)[-1] for url in requests]

    def shells(self):
        return ["sh"] + (["dash"] if shutil.which("dash") else [])

    def test_install_sh_passes_the_signed_checksums_to_install_py(self):
        for shell in self.shells():
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                result, requests = self.bootstrap(root, shell)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(requests, ["install.py", "SHA256SUMS", "SHA256SUMS.sig"])
                args = json.loads((root / "args.json").read_text())
                self.assertEqual(args[0], "--checksums")
                self.assertTrue(args[1].endswith("/SHA256SUMS"))
                self.assertEqual(args[2], "--signature")
                self.assertTrue(args[3].endswith("/SHA256SUMS.sig"))
                self.assertEqual(args[4:], ["--prefix", str(root / "prefix")])

    def test_install_sh_uses_lmx_python_or_else_python3_and_names_an_unusable_lmx_python(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result, requests = self.bootstrap(root, python=None)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(requests, ["install.py", "SHA256SUMS", "SHA256SUMS.sig"])
        # An interpreter that fails the version check, as Python 3.7 would.
        old = Path(tempfile.mkdtemp()) / "python3.7"
        old.write_text("#!/bin/sh\nexit 1\n")
        old.chmod(0o755)
        try:
            for python in ("/nonexistent/python3", str(old)):
                with self.subTest(python=python), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    result, requests = self.bootstrap(root, python=python)
                    self.assertEqual(result.returncode, 1)
                    self.assertIn(f"LMX_PYTHON is set to {python}, which is not a Python 3.8 or newer",
                                  result.stderr)
                    self.assertEqual(requests, [])
                    self.assertFalse((root / "args.json").exists())
        finally:
            shutil.rmtree(old.parent)

    def test_install_sh_stops_without_a_signature_or_on_a_mismatched_installer(self):
        def unsigned(release):
            (release / "SHA256SUMS.sig").unlink()

        def tampered(release):
            (release / "install.py").write_text(FAKE_INSTALLER + "# changed\n")

        for edit, message in ((unsigned, "is unsigned"), (tampered, "installer checksum mismatch")):
            with self.subTest(message=message), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                result, _ = self.bootstrap(root, edit=edit)
                self.assertEqual(result.returncode, 1)
                self.assertIn(message, result.stderr)
                self.assertFalse((root / "args.json").exists())


class PlatformTest(unittest.TestCase):
    def test_linux_arm64_and_other_platforms_point_at_the_source_checkout(self):
        message = installer.platform_error("Linux", "aarch64")
        self.assertIn("no Linux arm64 build", message)
        self.assertIn("use the source checkout: see docs/getting-started.md", message)
        self.assertIn("use the source checkout: see docs/getting-started.md",
                      installer.platform_error("FreeBSD", "amd64"))
        self.assertIn("lmx.cmd", installer.platform_error("Windows", "amd64"))
        self.assertIn("WSL", installer.platform_error("Windows", "amd64"))

    def test_linux_needs_glibc_2_34_and_refuses_musl(self):
        for libc in ("glibc 2.34", "glibc 2.35", "glibc 2.39", "glibc 2.43"):
            installer.linux_preflight(libc)
        with self.assertRaisesRegex(ValueError, "glibc 2.34 or newer; this system has glibc 2.31"):
            installer.linux_preflight("glibc 2.31")
        with self.assertRaisesRegex(ValueError, "glibc 2.34 or newer"):
            installer.linux_preflight("glibc 2.28")
        for libc in (None, "", "musl 1.2"):
            with self.assertRaisesRegex(ValueError, "musl distributions such as Alpine are not supported"):
                installer.linux_preflight(libc)
        # musl's confstr has no glibc version to report.
        with patch.object(installer.os, "confstr", side_effect=OSError(22, "Invalid argument")):
            self.assertIsNone(installer.gnu_libc())
        with patch.object(installer.os, "confstr", return_value="glibc 2.39"):
            self.assertEqual(installer.gnu_libc(), "glibc 2.39")

    def test_a_missing_ca_bundle_is_a_warning(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(installer.ca_warning([str(Path(directory) / "none.pem")]),
                             "warning: no CA certificates found; install ca-certificates or lmx cannot reach HTTPS providers")
            bundle = Path(directory) / "ca.pem"
            bundle.write_text("certificates")
            self.assertIsNone(installer.ca_warning([str(Path(directory) / "none.pem"), str(bundle)]))

    def test_root_installs_need_an_explicit_prefix(self):
        refusal = installer.root_refusal(False, euid=0, environ={"SUDO_USER": "alice"})
        self.assertIn("installs per user", refusal)
        self.assertIn("without sudo, as alice", refusal)
        self.assertIn("pass --prefix explicitly", refusal)
        self.assertIn("as the user who will run lmx", installer.root_refusal(False, euid=0, environ={}))
        self.assertIsNone(installer.root_refusal(True, euid=0, environ={}))
        self.assertIsNone(installer.root_refusal(False, euid=501, environ={}))

    def test_old_pythons_reach_the_version_check_instead_of_a_syntax_error(self):
        source = INSTALLER.read_text()
        try:
            ast.parse("(x := 1)", feature_version=(3, 6))
        except SyntaxError:
            pass
        else:
            self.skipTest("this Python's parser does not enforce older grammars")
        ast.parse(source, feature_version=(3, 6))
        body = ast.parse(source).body
        self.assertEqual(ast.dump(body[1]), ast.dump(ast.parse("import sys").body[0]))
        self.assertIsInstance(body[2], ast.If)
        self.assertEqual(ast.dump(body[2].test), ast.dump(ast.parse("sys.version_info < (3, 8)", mode="eval").body))


class DownloadTest(unittest.TestCase):
    class Response(io.BytesIO):
        def __init__(self, data, stall_after=None):
            super().__init__(data)
            self.stall_after = stall_after

        def read(self, size=-1):
            if self.stall_after is not None and self.tell() >= self.stall_after:
                raise socket.timeout("timed out")
            return super().read(size)

    class Clock:
        """Stands in for the time module: each monotonic() reading is `step` seconds after the last."""
        def __init__(self, step):
            self.now, self.step = 0.0, step

        def monotonic(self):
            reading, self.now = self.now, self.now + self.step
            return reading

    def test_slow_stalled_and_oversized_downloads_say_which(self):
        def serving(stall_after=None):
            return lambda *args, **kwargs: self.Response(b"x" * 200_000, stall_after)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(installer.urllib.request, "urlopen", side_effect=serving(70_000)):
                with self.assertRaisesRegex(ValueError, "lmx_linux.tar.gz stalled: no data for 30 seconds"):
                    installer.download("https://example.invalid/lmx_linux.tar.gz", root / "stalled")
            with patch.object(installer.urllib.request, "urlopen", side_effect=serving()):
                with self.assertRaisesRegex(ValueError, "SHA256SUMS is larger than 100,000 bytes"):
                    installer.download("https://example.invalid/SHA256SUMS", root / "large", 100_000)
                # 200,000 bytes arrive in four reads. At 700 seconds a read the
                # third passes the 30-minute deadline...
                with patch.object(installer, "time", self.Clock(700)), \
                        self.assertRaisesRegex(ValueError, "update.json took longer than 30 minutes"):
                    installer.download("https://example.invalid/update.json", root / "slow")
                # ...while at 400 seconds a read, a download taking 26 minutes
                # completes. The old 120-second cap failed it as "exceeds limit".
                with patch.object(installer, "time", self.Clock(400)):
                    installer.download("https://example.invalid/lmx_macos.tar.gz", root / "steady")
                self.assertEqual((root / "steady").stat().st_size, 200_000)
            missing = installer.urllib.error.HTTPError("https://example.invalid/SHA256SUMS.sig", 404, "Not Found",
                                                       {}, io.BytesIO(b"Not Found"))
            with patch.object(installer.urllib.request, "urlopen", side_effect=missing):
                with self.assertRaisesRegex(ValueError, "unsigned release"):
                    installer.download("https://example.invalid/SHA256SUMS.sig", root / "sig", 1_000,
                                       missing="refusing to install an unsigned release")


if __name__ == "__main__":
    unittest.main()
