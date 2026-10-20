"""Repository-shaped development diagnostics, not an independent public benchmark.

The host runs this generator before dispatch. Reference functions and private
examples never enter a task workspace. Families, rather than cosmetic variants,
are the conservative statistical clusters. No network or third-party package.
"""

import copy
import json
import pathlib
import sys


def graph(value):
    nodes = value["nodes"]
    if len(nodes) != len(set(nodes)):
        return None
    pending = {node: set() for node in nodes}
    for child, parent in value["edges"]:
        if child not in pending or parent not in pending:
            return None
        pending[child].add(parent)
    result = []
    while pending:
        ready = sorted(node for node, parents in pending.items() if not parents)
        if not ready:
            return None
        result.append(ready)
        pending = {node: parents - set(ready) for node, parents in pending.items() if node not in ready}
    return result


def journal(value):
    state, stack = {}, []
    for event in value:
        op = event[0]
        if op == "begin":
            stack.append(copy.deepcopy(state))
        elif op == "put":
            state[event[1]] = event[2]
        elif op == "delete":
            state.pop(event[1], None)
        elif op in ("commit", "rollback"):
            if not stack:
                return None
            before = stack.pop()
            if op == "rollback":
                state = before
        else:
            return None
    return None if stack else state


def cache(value):
    capacity, entries, output = value["capacity"], {}, []
    if not isinstance(capacity, int) or isinstance(capacity, bool) or capacity < 0:
        return None
    sequence = 0
    for event in value["events"]:
        now, op, key, *rest = event
        entries = {k: data for k, data in entries.items() if data[1] > now}
        sequence += 1
        if op == "put":
            data, ttl = rest
            entries.pop(key, None)
            if ttl > 0 and capacity:
                if len(entries) >= capacity:
                    del entries[min(entries, key=lambda k: entries[k][2])]
                entries[key] = (data, now + ttl, sequence)
        elif op == "get":
            if key in entries:
                data, expiry, _ = entries[key]
                entries[key] = (data, expiry, sequence)
                output.append(data)
            else:
                output.append(None)
        else:
            return None
    return output


def merge(value):
    def combine(base, overlay):
        result = copy.deepcopy(base)
        for key, item in overlay.items():
            if item == {"$delete": True}:
                result.pop(key, None)
            elif isinstance(item, dict) and isinstance(result.get(key), dict):
                result[key] = combine(result[key], item)
            else:
                result[key] = copy.deepcopy(item)
        return result
    result = {}
    for layer in value:
        if not isinstance(layer, dict):
            return None
        result = combine(result, layer)
    return result


def reconcile(value):
    current = {}
    for event in value:
        key, version = event["id"], event["version"]
        if not isinstance(version, int) or isinstance(version, bool) or version < 0:
            return None
        if key not in current or version >= current[key]["version"]:
            current[key] = event
    return [{"id": key, "value": current[key].get("value")} for key in sorted(current) if not current[key].get("deleted", False)]


def intervals(value):
    events = {}
    for start, end, weight in value:
        if start > end or weight < 0:
            return None
        if start == end or weight == 0:
            continue
        events[start] = events.get(start, 0) + weight
        events[end] = events.get(end, 0) - weight
    result, previous, load = [], None, 0
    for point in sorted(events):
        if previous is not None and load:
            if result and result[-1][1] == previous and result[-1][2] == load:
                result[-1][1] = point
            else:
                result.append([previous, point, load])
        load += events[point]
        previous = point
    return result


def allocation(value):
    total, weights = value["total"], value["weights"]
    if not isinstance(total, int) or isinstance(total, bool) or total < 0 or any(not isinstance(w, int) or isinstance(w, bool) or w < 0 for w in weights):
        return None
    denominator = sum(weights)
    if not denominator:
        return [] if not weights and total == 0 else ([0] * len(weights) if total == 0 else None)
    result = [total * w // denominator for w in weights]
    order = sorted(range(len(weights)), key=lambda i: (-(total * weights[i] % denominator), i))
    for i in order[:total - sum(result)]:
        result[i] += 1
    return result


def patch(value):
    document = copy.deepcopy(value["document"])
    original = copy.deepcopy(document)
    for operation in value["operations"]:
        path = operation["path"]
        if not path.startswith("/"):
            return {"ok": False, "document": original}
        keys = [key.replace("~1", "/").replace("~0", "~") for key in path[1:].split("/")]
        target = document
        for key in keys[:-1]:
            if not isinstance(target, dict) or key not in target:
                return {"ok": False, "document": original}
            target = target[key]
        key = keys[-1]
        if not isinstance(target, dict):
            return {"ok": False, "document": original}
        op = operation["op"]
        if op == "set":
            target[key] = copy.deepcopy(operation["value"])
        elif op == "remove" and key in target:
            del target[key]
        elif op == "test" and key in target and target[key] == operation["value"]:
            pass
        else:
            return {"ok": False, "document": original}
    return {"ok": True, "document": document}


FAMILIES = {
    "graph": (graph, "Return lexically sorted topological layers for nodes and [child,parent] edges. Deduplicate edges. Reject duplicate nodes, unknown endpoints, self dependencies and cycles with null. Empty graph returns [].", [
        {"nodes": ["c", "b", "a"], "edges": [["c", "a"]]},
        {"nodes": ["a", "b"], "edges": [["a", "b"], ["b", "a"]]},
        {"nodes": [], "edges": []}, {"nodes": ["a", "a"], "edges": []},
        {"nodes": ["a"], "edges": [["a", "z"]]},
        {"nodes": ["a", "b", "c"], "edges": [["c", "b"], ["b", "a"], ["b", "a"]]},
        {"nodes": ["z"], "edges": [["z", "z"]]},
        {"nodes": ["e", "d", "c", "b", "a"], "edges": [["d", "a"], ["d", "b"], ["e", "d"], ["e", "c"]]},
    ]),
    "journal": (journal, "Execute begin, put(key,value), delete(key), commit, rollback operations on an initially empty dictionary. Transactions nest; commit retains current changes, rollback restores the state at the innermost begin. Deleting a missing key is harmless. Unknown operations, unmatched commit/rollback or unclosed transactions return null.", [
        [["put", "a", 1], ["begin"], ["put", "a", 2], ["rollback"]],
        [["begin"], ["put", "a", 1], ["commit"]], [], [["commit"]], [["begin"]],
        [["put", "a", {"x": [1]}], ["begin"], ["begin"], ["put", "a", 2], ["commit"], ["rollback"]],
        [["delete", "missing"]], [["begin"], ["put", "a", 2], ["rollback"], ["rollback"]],
    ]),
    "cache": (cache, "Evaluate a capacity-bounded TTL LRU cache using supplied logical timestamps. events are [time,put,key,value,ttl] or [time,get,key]. Expire entries before each operation at expires<=time. Reads refresh LRU order but never extend TTL. Overwriting removes the old entry, including with ttl<=0. Evict least recently used live entry on new insertion. Return get results (null for misses). Reject invalid capacity (including bool) or unknown operations. Input timestamps are nondecreasing.", [
        {"capacity": 1, "events": [[0, "put", "a", 1, 2], [1, "get", "a"], [2, "get", "a"]]},
        {"capacity": 2, "events": [[0, "put", "a", 1, 9], [0, "put", "b", 2, 9], [1, "get", "a"], [1, "put", "c", 3, 9], [2, "get", "b"]]},
        {"capacity": 0, "events": [[0, "put", "x", 1, 9], [0, "get", "x"]]},
        {"capacity": True, "events": []}, {"capacity": -1, "events": []},
        {"capacity": 1, "events": [[0, "put", "a", 1, 9], [0, "put", "a", 2, 0], [0, "get", "a"]]},
        {"capacity": 1, "events": [[0, "put", "a", None, 2], [1, "get", "a"], [2, "get", "a"]]},
        {"capacity": 1, "events": [[0, "unknown", "x"]]},
    ]),
    "merge": (merge, "Apply dictionary layers in order. Recursively merge only when both existing and new values are dictionaries. Otherwise replace, including lists and null. The exact object {\"$delete\":true} removes a key if present; other objects containing $delete are ordinary values. Reject nondictionary layers with null. Preserve inputs.", [
        [{"a": {"b": 1, "c": 2}}, {"a": {"b": 3}}],
        [{"a": [1]}, {"a": [2]}], [], [{"a": 1}, {"a": {"$delete": True}}],
        [{"a": {"b": 1}}, {"a": None}], [{"a": 1}, 2],
        [{"a": {"b": 1}}, {"a": {"b": {"$delete": True}, "c": 2}}],
        [{"a": 1}, {"a": {"$delete": True, "extra": 2}}],
    ]),
    "reconcile": (reconcile, "Reconcile events by string id and nonnegative integer version (bool is invalid). Largest version wins; last input event wins version ties. A winning deleted:true is a tombstone and suppresses that id, including older later-arriving data. Return live [{id,value}] sorted by id; a missing value is null. Reject invalid versions with null.", [
        [{"id": "a", "version": 2, "value": 9}, {"id": "a", "version": 1, "value": 3}],
        [{"id": "a", "version": 1, "value": 2}, {"id": "a", "version": 1, "deleted": True}], [],
        [{"id": "a", "version": True}], [{"id": "a", "version": -1}],
        [{"id": "b", "version": 3, "deleted": True}, {"id": "b", "version": 2, "value": 7}],
        [{"id": "b", "version": 0}, {"id": "a", "version": 1, "value": False}],
        [{"id": "a", "version": 2, "deleted": True}, {"id": "a", "version": 3, "value": 4}],
    ]),
    "intervals": (intervals, "Convert weighted half-open intervals [start,end,weight] to sorted disjoint [start,end,total_weight] segments. Sum overlapping loads. Omit zero-load and empty segments. Merge adjacent segments of the same positive load. Reject start>end or negative weights with null. Endpoints and weights are integers.", [
        [[0, 3, 2], [1, 4, 1]], [[0, 1, 1], [1, 2, 1]], [], [[2, 1, 3]],
        [[1, 1, 9], [0, 2, 0]], [[-3, -1, 2], [-2, 0, 2]],
        [[0, 4, 1], [1, 2, 1], [2, 3, 1]], [[0, 2, -1]],
    ]),
    "allocation": (allocation, "Apportion integer total among nonnegative integer weights by largest remainder (Hamilton method). Reject bools, negative or noninteger totals/weights with null. Allocate floor(total*w/sum(weights)), then remaining units to largest exact fractional remainders, breaking ties by original index. Zero total permits all-zero or empty weights; positive total with zero weight sum returns null. Use integer arithmetic for arbitrarily large totals.", [
        {"total": 5, "weights": [1, 1, 1]}, {"total": 10, "weights": [1, 2, 3]},
        {"total": 0, "weights": []}, {"total": 3, "weights": [0, 0]},
        {"total": True, "weights": [1]}, {"total": 3, "weights": [True, 2]},
        {"total": 10**25 + 1, "weights": [1, 1, 1]},
        {"total": 7, "weights": [0, 1, 0]},
    ]),
    "patch": (patch, "Apply atomic dictionary-only patch operations. Paths start with / and use JSON Pointer ~1 for slash and ~0 for tilde. Empty keys are legal. Every intermediate key must exist and name a dictionary. set creates/replaces a final key; remove requires an existing key; test requires an existing key equal to value. On any invalid path/op/test return {ok:false,document:original}, undoing earlier operations. Otherwise return {ok:true,document:updated}. Preserve input objects. Lists are values, not traversable containers.", [
        {"document": {"a": 1}, "operations": [{"op": "set", "path": "/a", "value": 2}]},
        {"document": {"a": 1}, "operations": [{"op": "set", "path": "/a", "value": 2}, {"op": "test", "path": "/a", "value": 1}]},
        {"document": {"a/b": {"~": 1}}, "operations": [{"op": "set", "path": "/a~1b/~0", "value": 9}]},
        {"document": {}, "operations": [{"op": "remove", "path": "/missing"}]},
        {"document": {"a": []}, "operations": [{"op": "set", "path": "/a/0", "value": 9}]},
        {"document": {}, "operations": [{"op": "set", "path": "/", "value": 7}]},
        {"document": {}, "operations": [{"op": "set", "path": "a", "value": 9}]},
        {"document": {"a": {}}, "operations": [{"op": "set", "path": "/a/x", "value": [1]}, {"op": "remove", "path": "/a/x"}]},
    ]),
}


def materialize(root, partition, variants):
    fixtures = []
    for family, (reference, contract, examples) in FAMILIES.items():
        for variant in range(variants):
            task_id = f"{partition}-{family}-{variant + 1}"
            path = pathlib.Path(root) / task_id
            files = {
                "README.md": f"Repository case {task_id}. A small repository with a generated runtime. Read docs/development.md before changing code. The issue is in ISSUE.md.\n",
                "ISSUE.md": f"Repair the {family} feature end to end. The authoritative behavior is in docs/contract.md. Preserve the JSON CLI and all existing contracts. Do not edit tests, docs, runner, or build tooling.\n",
                "docs/contract.md": contract + "\nThe JSON CLI applies solve independently to every input and emits a JSON list.\n",
                "docs/development.md": "Source lives under src/project. main.py imports the GENERATED runtime from .build/project, which is initially stale. Edit source, run python tools/build.py, then python checks.py. Both source and generated runtime must agree at delivery. The grader may rebuild from source. Python standard library only. Do not put implementations in the CLI or build script.\n",
                "src/project/__init__.py": "",
                "src/project/core.py": "from .policy import valid\n\ndef solve(value):\n    if not valid(value):\n        return None\n    return value\n",
                "src/project/policy.py": "def valid(value):\n    return value is not None\n",
                ".build/project/__init__.py": "",
                ".build/project/core.py": "def solve(value):\n    return None\n",
                ".build/project/policy.py": "def valid(value):\n    return False\n",
                "main.py": "import json,sys\nsys.path.insert(0, '.build')\nfrom project.core import solve\nprint(json.dumps([solve(x) for x in json.loads(sys.argv[1])]))\n",
                "tools/build.py": "import pathlib,shutil\nroot=pathlib.Path(__file__).resolve().parents[1]\nshutil.rmtree(root/'.build', ignore_errors=True)\nshutil.copytree(root/'src', root/'.build')\nprint('runtime rebuilt')\n",
                "pyproject.toml": '[project]\nname = "workflow-diagnostic"\nversion = "0.1.0"\nrequires-python = ">=3.11"\n',
            }
            # Public verification and private confirmation use distinct inputs.
            # A separate partition changes task identity and ordering, never the
            # declared independence count or the source of the expected results.
            offset = (variant + (1 if partition == "confirmation" else 0)) % 2
            public = examples[offset::2][:2]
            private = [item for i, item in enumerate(examples) if i % 2 != offset] + examples[offset::2][2:]
            public_cases = [[item, reference(copy.deepcopy(item))] for item in public]
            private_cases = [[item, reference(copy.deepcopy(item))] for item in private]
            files["checks.py"] = "import json,subprocess,sys\ncases=json.loads(" + repr(json.dumps(public_cases)) + ")\nactual=json.loads(subprocess.check_output([sys.executable,'main.py',json.dumps([x for x,_ in cases])]))\nassert actual==[y for _,y in cases], (actual,cases)\nprint('public checks passed')\n"
            for i in range(12):
                files[f"src/project/legacy_{i}.py"] = f'"""Retired adapter {i}; not imported by the current runtime."""\nVERSION = {i}\n'
            for name, data in files.items():
                target = path / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(data)
            mutable = {"src/project/core.py", "src/project/policy.py", ".build/project/core.py", ".build/project/policy.py"}
            fixtures.append({
                "id": task_id, "cluster": family, "cwd": str(path),
                "cases": private_cases, "probe_cases": public_cases,
                "immutable": {name: data for name, data in files.items() if name not in mutable},
                "reference_guidance": "Batch-read ISSUE.md, docs/contract.md, docs/development.md, src/project/core.py and src/project/policy.py. Implement in source; rebuild the generated runtime with python tools/build.py; execute public checks; verify edge cases from the written contract and inspect both source and built runtime. Do not treat the old generated copy as authoritative.",
            })
    return fixtures


if __name__ == "__main__":
    print(json.dumps(materialize(sys.argv[1], sys.argv[2], int(sys.argv[3]))))
