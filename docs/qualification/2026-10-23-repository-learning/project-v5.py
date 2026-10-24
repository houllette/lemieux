"""Project sealed private v5 runs into bounded public facts, without model calls.

Usage: python3 project-v5.py PRIVATE_ARTIFACT_PARENT PUBLIC_OUTPUT_DIRECTORY
The output directory must be new. Raw runs and allowance files are never edited.
"""
import collections
import hashlib
import json
import pathlib
import sys

root, output = map(pathlib.Path, sys.argv[1:])
output.mkdir()


def read(path):
    return json.loads(path.read_bytes())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def project(name, mechanism):
    run = root / name
    report = read(run / "report.json")
    physical = {}
    skill_reads = []
    evidence = []
    for path in sorted(run.glob("*/evidence.json")):
        record = read(path)
        evidence.append(digest(path))
        for key, call in record["physical_dispatches"].items():
            assert key not in physical
            physical[key] = call
        context = record["context"]
        if record.get("asset_application"):
            calls = [
                call
                for event in record["selected"]["transcript"]
                if event["type"] == "assistant"
                for call in event["payload"].get("tool_calls", [])
                if call["name"] == "skill"
                and call["arguments"].get("file", "SKILL.md") == "SKILL.md"
            ]
            skill_reads.append({"arm": context["arm"], "repetition": context["repetition"],
                                "selected_skill_reads": len(calls)})
    known = [v for v in physical.values() if isinstance(v.get("tokens"), int)]
    roles = collections.defaultdict(lambda: {"requests": 0, "known_tokens": 0, "unknown_requests": 0})
    for call in physical.values():
        role = roles[call["role"]]
        role["requests"] += 1
        if isinstance(call.get("tokens"), int):
            role["known_tokens"] += call["tokens"]
        else:
            role["unknown_requests"] += 1
    rows = report["rows"]
    facts = {
        "schema_version": 1,
        "source_revision": report["runtime"]["revision"],
        "source_report_bytes_sha256": digest(run / "report.json"),
        "source_plan_bytes_sha256": digest(run / "plan.json"),
        "source_evidence_bytes_sha256": evidence,
        "plan_sha256": report["plan_sha256"],
        "inference_route": "codex_subscription",
        "executor": "openai_codex:gpt-6.1-sol/high",
        "editor": "openai_codex:gpt-6-astra/high",
        "physical_requests": len(physical),
        "known_usage_requests": len(known),
        "known_tokens": sum(v["tokens"] for v in known),
        "unknown_usage_requests": len(physical) - len(known),
        "tokens": sum(v["tokens"] for v in known) if len(physical) == len(known) else None,
        "roles": dict(roles),
        "rows": [{key: row.get(key) for key in (
            "task_id", "arm", "repetition", "passed", "requests", "tokens",
            "qualification_complete", "asset_application_count", "asset_restoration_count",
            "evidence_sha256")} for row in rows],
        "benefit": "unassessed",
        "independent_confirmation": "not_run",
        "default_activation": False,
        "raw_artifacts_modified": False,
    }
    if mechanism:
        receipt = read(run / "mechanism.json")
        facts.update({
            "kind": "hosted_text_skill_mechanism",
            "corpus": "developer_exposed_synthetic_graph_diagnostic",
            "task_horizon": 12,
            "warmup_rows": len(report["warmup_rows"]),
            "execution_complete": report["execution_complete"],
            "mechanism": {key: receipt[key] for key in (
                "status", "required_checks", "observed_checks", "interpretation", "sha256")},
            "source_mechanism_bytes_sha256": digest(run / "mechanism.json"),
            "selected_skill_reads": skill_reads,
            "research_endpoints": report["research_endpoints"],
            "independent_streams": 1,
            "adequately_powered": False,
        })
    else:
        facts.update({
            "kind": "incomplete_development_calibration",
            "corpus": "developer_exposed_hgrecco_pint",
            "task_horizon": 48,
            "status": "incomplete",
            "execution_complete": False,
            "baseline_success": None,
            "has_headroom": None,
            "raw_report_baseline_success_unusable": report["baseline_success"],
            "zero_dispatch_rows": sum(row["requests"] == 0 for row in rows),
            "unknown_token_rows": sum(row["tokens"] is None for row in rows),
            "failure": "server_is_overloaded_then_shared_allowance_usage_unknown",
            "failure_evidence": "retained_driver_warning_and_unmeasured_physical_receipt",
            "authoritative_missing_usage": "not_recovered",
            "interpretation": "Infrastructure interruption and admission refusal; no ability score or headroom inference.",
        })
    return facts


for filename, name, mechanism in [
    ("hosted-text-skill-mechanism-v5.json", "learning-text-skill-sol-astra-mechanism12-v5-2026-10-24", True),
    ("pint-calibration-v5-incomplete.json", "learning-fresh-pint-sol48-text-v5-calibration-2026-10-24", False),
]:
    (output / filename).write_text(json.dumps(project(name, mechanism), indent=2, sort_keys=True) + "\n")
