"""Offline checks for source-preserving development fixture preparation."""
import importlib.util
import io
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "scripts/prepare_learning_repository.py"
SPEC = importlib.util.spec_from_file_location("learning_repository_prepare", SOURCE)
PREPARE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREPARE)


class LearningRepositoryPrepareTest(unittest.TestCase):
    def test_nested_repository_patch_changes_exact_source_and_removes_private_git(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "-c", "init.templateDir=", "init", "-q", str(root)], check=True)
            child = root / "copy with spaces"
            child.mkdir()
            (child / "value.py").write_text("broken\n")
            patch = root / "fix.patch"
            patch.write_text("diff --git a/value.py b/value.py\n--- a/value.py\n+++ b/value.py\n@@ -1 +1 @@\n-broken\n+fixed\n")
            self.assertEqual(PREPARE.apply_patch(child, patch), ["value.py"])
            self.assertEqual((child / "value.py").read_text(), "fixed\n")
            self.assertFalse((child / ".git").exists())
            self.assertTrue((root / ".git").exists())

    def test_bad_patch_preserves_bytes_and_removes_temporary_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            (source / "value.py").write_text("original\n")
            patch = root / "bad.patch"
            patch.write_text("not a patch")
            with self.assertRaises(subprocess.CalledProcessError):
                PREPARE.apply_patch(source, patch)
            self.assertEqual((source / "value.py").read_text(), "original\n")
            self.assertFalse((source / ".git").exists())

    def test_archive_cannot_escape_or_restore_links(self):
        for name, kind in [("../outside", tarfile.REGTYPE), ("/absolute", tarfile.REGTYPE),
                           ("link", tarfile.SYMTYPE), ("hard", tarfile.LNKTYPE)]:
            data = io.BytesIO()
            with tarfile.open(fileobj=data, mode="w") as archive:
                entry = tarfile.TarInfo(name)
                entry.type = kind
                entry.linkname = "/outside"
                archive.addfile(entry)
            with tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(ValueError):
                    PREPARE.safe_extract(data.getvalue(), Path(directory) / "source")

    def test_archive_preserves_regular_file_bytes(self):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode="w") as archive:
            entry = tarfile.TarInfo("package/value.py")
            entry.size = 6
            archive.addfile(entry, io.BytesIO(b"value\n"))
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "source"
            PREPARE.safe_extract(data.getvalue(), destination)
            self.assertEqual((destination / "package/value.py").read_bytes(), b"value\n")


if __name__ == "__main__":
    unittest.main()
