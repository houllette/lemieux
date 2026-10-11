"""The stress runner gathers evidence without turning a failed attempt green."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/check_flakes.sh"


class CheckFlakesTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.log = self.directory / "calls.jsonl"
        mix = self.directory / "mix"
        mix.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "with open(os.environ['FLAKE_TEST_LOG'], 'a') as output:\n"
            "    output.write(json.dumps({'args': sys.argv[1:], "
            "'spend': os.environ.get('LEMIEUX_ALLOW_SPEND'), "
            "'env': os.environ.get('MIX_ENV')}) + '\\n')\n"
            "args = sys.argv[1:]\n"
            "if args[0] == 'test' and "
            "args[args.index('--seed') + 1] == os.environ.get('FLAKE_TEST_FAIL_SEED'):\n"
            "    sys.exit(1)\n"
            "if args[0] == 'temper.report':\n"
            "    sys.exit(int(os.environ.get('FLAKE_TEST_REPORT_STATUS', '0')))\n"
        )
        mix.chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": f"{self.directory}{os.pathsep}{os.environ['PATH']}",
            "FLAKE_TEST_LOG": str(self.log),
            "LEMIEUX_ALLOW_SPEND": "1",
            "MIX_ENV": "prod",
        }

    def run_script(self, *args):
        result = subprocess.run(
            ["bash", str(SCRIPT), *args],
            cwd=self.directory,
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
        )
        calls = (
            [json.loads(line) for line in self.log.read_text().splitlines()]
            if self.log.exists() else []
        )
        return result, calls

    def test_varies_seeds_and_forces_offline_test_environment(self):
        result, calls = self.run_script(
            "--runs", "3", "--seed", "101", "--max-cases", "4", "test/lemieux_test.exs"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 4)
        for call, seed in zip(calls[:3], ["101", "102", "103"]):
            self.assertEqual(call["args"], [
                "test", "--warnings-as-errors", "--seed", seed,
                "--max-cases", "4", "test/lemieux_test.exs",
            ])
            self.assertIsNone(call["spend"])
            self.assertEqual(call["env"], "test")
        self.assertEqual(calls[-1]["args"], ["temper.report"])

    def test_keeps_failure_after_later_attempts_pass_and_still_reports(self):
        self.env["FLAKE_TEST_FAIL_SEED"] = "102"
        result, calls = self.run_script("--runs", "3", "--seed", "101")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 4)
        self.assertEqual(calls[-1]["args"], ["temper.report"])

    def test_report_failure_is_not_hidden(self):
        self.env["FLAKE_TEST_REPORT_STATUS"] = "1"
        result, calls = self.run_script("--runs", "2")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 3)

    def test_rejects_unbounded_runs_and_paid_test_flags_before_starting(self):
        invalid = [
            ("--runs", "0"), ("--runs", "21"), ("--runs", "x"),
            ("--only", "live"), ("--include", "eval_live"),
            ("--max-cases", "0"), ("--seed", "-1"), ("--runs",),
        ]
        for args in invalid:
            with self.subTest(args=args):
                result, calls = self.run_script(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [])

    def test_accepts_line_selector_and_decimal_options_with_leading_zeroes(self):
        result, calls = self.run_script("--runs", "02", "--seed", "000", "test/lemieux_test.exs:10")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("test/lemieux_test.exs:10", calls[0]["args"])
        self.assertEqual(calls[0]["args"][3], "0")

    def test_rejects_invalid_or_missing_test_paths(self):
        for path in ["mix.exs", "test/missing_test.exs", "test/lemieux_test.exs:invalid"]:
            with self.subTest(path=path):
                result, calls = self.run_script(path)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
