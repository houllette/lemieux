"""Validate the development corpus independently of hosted model outcomes."""

import importlib.util
import inspect
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

GENERATOR = pathlib.Path(__file__).resolve().parents[1] / "priv/qualification/projects.py"
SPEC = importlib.util.spec_from_file_location("qualification_projects", GENERATOR)
PROJECTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROJECTS)


class QualificationProjectsTest(unittest.TestCase):
    def test_reference_edge_contracts(self):
        self.assertEqual(PROJECTS.graph({"nodes": ["b", "a", "c"], "edges": [["c", "a"]]}), [["a", "b"], ["c"]])
        self.assertIsNone(PROJECTS.graph({"nodes": ["a", "a"], "edges": []}))
        self.assertEqual(PROJECTS.intervals([[0, 1, 2], [1, 2, 2]]), [[0, 2, 2]])
        self.assertEqual(PROJECTS.journal([["put", "x", 1], ["begin"], ["begin"], ["put", "x", 3], ["commit"], ["rollback"]]), {"x": 1})
        self.assertEqual(PROJECTS.cache({"capacity": 1, "events": [[0, "put", "a", 2, 1], [1, "get", "a"]]}), [None])
        self.assertEqual(PROJECTS.patch({"document": {"a": 1}, "operations": [{"op": "set", "path": "/a", "value": 2}, {"op": "test", "path": "/a", "value": 1}]}), {"ok": False, "document": {"a": 1}})
        self.assertIsNone(PROJECTS.allocation({"total": True, "weights": [1]}))
        self.assertEqual(sum(PROJECTS.allocation({"total": 10**25 + 1, "weights": [1, 1, 1]})), 10**25 + 1)

    def test_every_broken_repository_fails_and_reference_passes_both_case_sets(self):
        with tempfile.TemporaryDirectory(prefix="lemieux-corpus-") as directory:
            fixtures = PROJECTS.materialize(directory, "development", 2)
            self.assertEqual(len(fixtures), 16)
            self.assertEqual(len({item["cluster"] for item in fixtures}), 8)
            for fixture in fixtures:
                with self.subTest(task=fixture["id"]):
                    root = pathlib.Path(fixture["cwd"])
                    cases = fixture["probe_cases"] + fixture["cases"]
                    inputs = json.dumps([item[0] for item in cases])
                    expected = [item[1] for item in cases]
                    broken = subprocess.check_output([sys.executable, "main.py", inputs], cwd=root)
                    self.assertNotEqual(json.loads(broken), expected)
                    reference = PROJECTS.FAMILIES[fixture["cluster"]][0]
                    source = "import copy\n" + inspect.getsource(reference) + f"\nsolve = {reference.__name__}\n"
                    (root / "src/project/core.py").write_text(source)
                    shutil.rmtree(root / ".build")
                    shutil.copytree(root / "src", root / ".build")
                    actual = subprocess.check_output([sys.executable, "main.py", inputs], cwd=root)
                    self.assertEqual(json.loads(actual), expected)
                    workspace = "\n".join(path.read_text() for path in root.rglob("*.py") if "core.py" != path.name)
                    self.assertNotIn("FAMILIES =", workspace)
                    self.assertNotIn("private_cases", workspace)

    def test_parameter_variants_are_fresh_without_inflating_family_count(self):
        with tempfile.TemporaryDirectory(prefix="lemieux-corpus-fresh-") as directory:
            fixtures = PROJECTS.materialize(directory, "development", 2)
            graph = [item for item in fixtures if item["cluster"] == "graph"]
            first = {json.dumps(x) for x, _ in graph[0]["cases"] if x["nodes"]}
            second = {json.dumps(x) for x, _ in graph[1]["cases"] if x["nodes"]}
            self.assertFalse(first.intersection(second))
            self.assertEqual(graph[0]["cluster"], graph[1]["cluster"])


if __name__ == "__main__":
    unittest.main()
