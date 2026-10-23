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
    def test_patch_symlink_is_refused_before_reading_its_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            (source / "value").write_text("original")
            outside = root / "outside"
            outside.write_text("private bytes")
            patch = root / "link.patch"
            patch.write_text("diff --git a/link b/link\nnew file mode 120000\n--- /dev/null\n+++ b/link\n@@ -0,0 +1 @@\n+../outside\n")
            with self.assertRaisesRegex(ValueError, "symlink"):
                PREPARE.apply_patch(source, patch)
            self.assertEqual(outside.read_text(), "private bytes")
            self.assertFalse((source / ".git").exists())

    def test_oracle_keeps_original_instructions_and_reference_implementation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            (source / "value.py").write_text("broken\n")
            (source / "README.md").write_text("original contract\n")
            patch = root / "fix.patch"
            patch.write_text("diff --git a/value.py b/value.py\n--- a/value.py\n+++ b/value.py\n@@ -1 +1 @@\n-broken\n+fixed\n"
                             "diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-original contract\n+changed instructions\n")
            oracle = root / "oracle"
            PREPARE.project_oracle(source, oracle, patch, ["README.md"])
            self.assertEqual((oracle / "value.py").read_text(), "fixed\n")
            self.assertEqual((oracle / "README.md").read_text(), "original contract\n")
            self.assertEqual((source / "value.py").read_text(), "broken\n")

    def test_pytest_node_ids_preserve_paths_and_select_all_parameter_variants(self):
        paths, names = PREPARE.pytest_selection([
            "tests/test_values.py::TestValues::test_round_trip[unicode]",
            "tests/test_values.py::TestValues::test_round_trip[ascii]",
            "tests/test_other.py::test_boundary",
        ])
        self.assertEqual(paths, ["tests/test_other.py", "tests/test_values.py"])
        self.assertEqual(names, ["test_round_trip", "test_boundary"])
        self.assertEqual(PREPARE.pytest_selection(["test_legacy"]), ([], ["test_legacy"]))

    def test_pytest_selectors_cannot_escape_or_inject_ini_options(self):
        for selector in ["../test.py::test_value", "/test.py::test_value",
                         "tests\\test.py::test_value", "test.py::test_x or True",
                         "test.py::test_x\naddopts=-x"]:
            with self.assertRaises(ValueError):
                PREPARE.pytest_selection([selector])

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
