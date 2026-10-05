"""Tests for the CI gate scripts: links, public wording and static OTP pins.

Each test builds a throwaway Git repository, so the scripts run against
known content instead of this checkout's, which later changes would move.
"""
import codecs
import contextlib
import importlib.util
import io
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

# Both gates read this file in CI, so neither value appears literally: the
# name is the one check_public_text.sh looks for, stored ROT13-encoded as the
# script stores it, and the URL is split so check_links.py does not report a
# link to a private repository here.
PRIVATE_NAME = codecs.decode("Pubehf", "rot13")
PRIVATE_REPOSITORY_URL = "https://github.com/" + "houllette/secret-host"


def load_check_links():
    spec = importlib.util.spec_from_file_location("check_links", ROOT / "scripts" / "check_links.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


check_links = load_check_links()


@contextlib.contextmanager
def repository(files):
    """A Git repository holding `files` (path -> text), all of them tracked."""
    with tempfile.TemporaryDirectory(prefix="lemieux-ci-scripts-") as directory:
        root = Path(directory)
        for name, text in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)
        yield root


def run_links(root, *files):
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        status = check_links.main(["--root", str(root), *files])
    return status, output.getvalue()


class GithubAnchorsTest(unittest.TestCase):
    def test_anchor_text_follows_github(self):
        anchors = check_links.anchors(
            "# Title\n\n## The `mix lmx` task\n\n## Replacing a tool's receipt\n\n"
            "## Q&A: what's [new](x.md)?\n\n## Title\n\nSetext heading\n--------------\n\n"
            '<a name="Custom-Spot"></a>\n\n```md\n## Not a heading\n```\n')
        self.assertEqual(anchors, {
            "title", "the-mix-lmx-task", "replacing-a-tools-receipt", "qa-whats-new",
            "title-1", "setext-heading", "custom-spot"})


class CheckLinksTest(unittest.TestCase):
    FILES = {
        "README.md": "# Read me\n\n[guide](docs/guide.md#second-part) [root](/docs/guide.md)\n",
        "docs/guide.md": (
            "# Guide\n\n## Second part\n\n"
            "[here](#guide) [examples](../examples/) [image](../assets/pic.png)\n\n"
            "[later]: guide.md#second-part\n\n"
            "See https://github.com/houllette/lemieux/blob/main/docs/guide.md#second-part.\n\n"
            "```sh\n[not a link](nowhere.md)\n```\n"),
        "examples/run.exs": "IO.puts(:ok)\n",
        "assets/pic.png": "not really a picture\n",
        "eval/corpus/fixture/README.md": "[broken on purpose](missing.md)\n",
    }

    def test_a_clean_tree_passes(self):
        with repository(self.FILES) as root:
            status, output = run_links(root)
        self.assertEqual(status, 0, output)
        self.assertIn("0 broken", output)

    def test_reports_targets_anchors_and_private_repositories(self):
        files = dict(self.FILES)
        files["docs/broken.md"] = (
            "[gone](missing.md) [anchor](guide.md#no-such-part) [self](#nowhere)\n"
            "[up](../../outside.md)\n"
            "[main](https://github.com/houllette/lemieux/blob/main/docs/absent.md)\n"
            "[pinned](https://github.com/houllette/lemieux/tree/0123abc/docs)\n")
        files["lib/thing.ex"] = '@url "%s/issues"\n' % PRIVATE_REPOSITORY_URL
        with repository(files) as root:
            status, output = run_links(root)
        self.assertEqual(status, 1, output)
        self.assertIn("docs/broken.md:1: error: missing.md: docs/missing.md does not exist", output)
        self.assertIn("no heading in docs/guide.md has the anchor #no-such-part", output)
        self.assertIn("no heading in docs/broken.md has the anchor #nowhere", output)
        self.assertIn("docs/broken.md:2: error: ../../outside.md: points outside the repository", output)
        self.assertIn("docs/absent.md does not exist", output)
        self.assertIn("docs/broken.md:4: warning:", output)
        self.assertIn("lib/thing.ex:1: error: %s" % PRIVATE_REPOSITORY_URL, output)
        self.assertNotIn("eval/corpus", output)
        self.assertIn("6 broken, 1 warnings", output)

    def test_untracked_targets_are_named_as_such(self):
        with repository(self.FILES) as root:
            (root / "docs" / "new.md").write_text("# New\n")
            (root / "docs" / "guide.md").write_text("[new](new.md)\n")
            status, output = run_links(root, str(root / "docs" / "guide.md"))
        self.assertEqual(status, 1)
        self.assertIn("docs/new.md exists here but is not tracked", output)


class CheckPublicTextTest(unittest.TestCase):
    def run_script(self, files):
        with repository(files) as root:
            (root / "scripts").mkdir(exist_ok=True)
            shutil.copy2(ROOT / "scripts" / "check_public_text.sh", root / "scripts")
            subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)
            return subprocess.run(["sh", str(root / "scripts" / "check_public_text.sh")],
                                  capture_output=True, text=True)

    def test_clean_tree_passes(self):
        result = self.run_script({"docs/a.md": "An embedding host.\n"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_reports_the_private_name_in_any_file_and_case(self):
        result = self.run_script({"lib/a.ex": "# used by %s\n" % PRIVATE_NAME.upper(),
                                  "notes.txt": "see %sHost\n" % PRIVATE_NAME})
        self.assertEqual(result.returncode, 1)
        self.assertIn("appears on 2 lines in 2 files", result.stdout)
        self.assertIn("lib/a.ex:1:", result.stdout)

    def test_neither_gate_file_spells_out_the_name_it_looks_for(self):
        # Bracketed ("[x]yz") or split ("xy" + "z") spellings defeat grep but
        # not a reader, so letters separated only by other characters count.
        spelled = re.compile("[^a-z]*".join(PRIVATE_NAME.lower()))
        for name in ("scripts/check_public_text.sh", "test/test_ci_scripts.py"):
            with self.subTest(name=name):
                self.assertIsNone(spelled.search((ROOT / name).read_text().lower()))

    def test_a_failing_search_is_an_error_not_a_clean_result(self):
        # git grep exits 128 on a pathspec outside the repository. Read as
        # "no match", that once printed the all-clear over a tree that still
        # named the private project.
        result = self.run_script({
            "docs/a.md": "Mentions %s.\n" % PRIVATE_NAME,
            "scripts/public_text_allowlist.txt": "../outside\n"})
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("git grep failed", result.stderr)
        self.assertNotIn("check_public_text: no ", result.stdout)

    def test_reports_launch_wording_in_markdown_and_elixir_only(self):
        result = self.run_script({
            "README.md": "This repository is currently private.\n",
            "lib/b.ex": "# Repository access is required while the project is private.\n",
            "CHANGELOG.md": "- No public binary before 0.1.0.\n",
            "scripts/x.sh": "# not advertised yet\n"})
        self.assertEqual(result.returncode, 1)
        self.assertIn("Launch-state wording remains on 2 lines", result.stdout)
        self.assertNotIn("CHANGELOG.md", result.stdout)
        self.assertNotIn("scripts/x.sh", result.stdout)

    def test_allowlisted_paths_are_skipped(self):
        result = self.run_script({
            "docs/a.md": "Mentions %s.\n" % PRIVATE_NAME,
            "scripts/public_text_allowlist.txt": "# The page quotes it on purpose.\ndocs/a.md\n"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


class StaticOtpPinsTest(unittest.TestCase):
    def check_pins(self, tool_versions):
        with tempfile.TemporaryDirectory(prefix="lemieux-static-otp-") as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            shutil.copy2(ROOT / "scripts" / "build-static-otp.sh", root / "scripts")
            (root / ".tool-versions").write_text(tool_versions)
            return subprocess.run(["bash", str(root / "scripts" / "build-static-otp.sh"), "--check-pins"],
                                  capture_output=True, text=True)

    def test_this_checkouts_toolchain_is_pinned(self):
        result = self.check_pins((ROOT / ".tool-versions").read_text())
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_an_unpinned_otp_version_fails_before_release_time(self):
        result = self.check_pins("erlang 29.0.99\nelixir 1.20.2-otp-29\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no pinned SHA-256 for otp_src_29.0.99.tar.gz", result.stderr)

    def test_elixir_must_be_built_for_the_otp_major(self):
        result = self.check_pins("erlang 29.0.2\nelixir 1.20.2-otp-28\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("not built for OTP 29", result.stderr)


if __name__ == "__main__":
    unittest.main()
