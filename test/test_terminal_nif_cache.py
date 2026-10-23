import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "scripts/cache_terminal_nif.py"
SPEC = importlib.util.spec_from_file_location("terminal_nif_cache", SOURCE)
CACHE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CACHE)


class TerminalNifCacheTest(unittest.TestCase):
    def test_matches_runtime_abi_and_platform_without_changing_native_version(self):
        checksum = "a" * 64
        text = "\n".join(f'"{prefix}ex_ratatui-v0.18.0-nif-{nif}-{target}.so.tar.gz" => "sha256:{checksum}"'
                         for nif in ["2.16", "2.17", "2.18"]
                         for prefix in (["lib"] if nif != "2.16" else [""])
                         for target in ["x86_64-unknown-linux-gnu", "aarch64-apple-darwin"])
        name, version, actual = CACHE.select(text, "2.17", "Linux", "x86_64")
        self.assertEqual(name, "libex_ratatui-v0.18.0-nif-2.17-x86_64-unknown-linux-gnu.so.tar.gz")
        self.assertEqual((version, actual), ("0.18.0", checksum))
        self.assertIn("2.18-aarch64-apple-darwin", CACHE.select(text, "2.18", "Darwin", "arm64")[0])
        with self.assertRaises(ValueError):
            CACHE.select(text, "2.18", "Linux", "x86_64", "musl")

    def test_tampered_download_never_enters_the_cache(self):
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)
            selection = ("libexample.so.tar.gz", "0.18.0", hashlib.sha256(b"expected").hexdigest())
            def fetch(_url, path):
                path.write_bytes(b"tampered")
            with self.assertRaisesRegex(ValueError, "wrong checksum"):
                CACHE.cache(directory, selection, fetch)
            self.assertEqual(list(directory.iterdir()), [])

    def test_verified_cache_is_reused_and_existing_tampering_is_refused(self):
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)
            selection = ("libexample.so.tar.gz", "0.18.0", hashlib.sha256(b"expected").hexdigest())
            urls = []
            def fetch(url, path):
                urls.append(url)
                path.write_bytes(b"expected")
            path = CACHE.cache(directory, selection, fetch)
            self.assertEqual(CACHE.cache(directory, selection, fetch), path)
            self.assertEqual(len(urls), 1)
            path.write_bytes(b"tampered")
            with self.assertRaisesRegex(ValueError, "existing CI cache"):
                CACHE.cache(directory, selection, fetch)
            self.assertEqual(len(urls), 1)
