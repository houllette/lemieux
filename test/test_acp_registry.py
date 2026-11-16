"""Registry distribution metadata must match the actual release archive layout."""
import importlib.util
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location(
    "acp_registry", Path(__file__).resolve().parents[1] / "scripts" / "acp_registry.py"
)
registry = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(registry)


class AcpRegistryTest(unittest.TestCase):
    def test_versioned_archives_checksums_and_platform_launchers(self):
        digest = "ab" * 32
        sums = "\n".join(f"{digest}  {name}" for name, _ in registry.PLATFORMS.values())
        entry = registry.build_entry("1.2.3", sums)
        binary = entry["distribution"]["binary"]
        self.assertEqual(set(binary), set(registry.PLATFORMS))
        for platform, (archive, command) in registry.PLATFORMS.items():
            self.assertEqual(binary[platform], {
                "archive": f"https://github.com/houllette/lemieux/releases/download/v1.2.3/{archive}",
                "sha256": digest, "cmd": command, "args": ["acp"],
            })
        self.assertEqual(entry["license_url"], "https://github.com/houllette/lemieux/blob/v1.2.3/LICENSE")

    def test_partial_platform_coverage_only_declares_available_archives(self):
        entry = registry.build_entry("1.2.3", f"{'ab' * 32} *lmx_macos_silicon.tar.gz")
        self.assertEqual(set(entry["distribution"]["binary"]), {"darwin-aarch64"})

    def test_invalid_or_ambiguous_release_metadata_is_rejected(self):
        for version, checksums in [
            ("latest", f"{'ab' * 32} lmx_linux.tar.gz"),
            ("1.2.3", "broken lmx_linux.tar.gz"),
            ("1.2.3", f"{'ab' * 32} unknown.tar.gz"),
            ("1.2.3", f"{'ab' * 32} lmx_linux.tar.gz\n{'cd' * 32} lmx_linux.tar.gz"),
        ]:
            with self.subTest(version=version, checksums=checksums), self.assertRaises(ValueError):
                registry.build_entry(version, checksums)


if __name__ == "__main__":
    unittest.main()
