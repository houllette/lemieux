"""Project the frozen study schemas into a portable, reviewed audit archive.

Usage: python3 project_evidence.py PRIVATE_RUN_ROOT PUBLIC_OUTPUT_DIRECTORY

This checks evidence hashes and usage reconciliation. It is not an automatic
redactor for arbitrary corpora: review metadata and grade labels before sharing.
"""

import argparse
import hashlib
import json
import pathlib
import shutil


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def project_episode(path, rows):
    evidence = json.loads(path.read_text())
    context = evidence["context"]
    key = (context["task"]["id"], context["arm"], context["repetition"])
    row = rows.pop(key)
    meter = evidence.get("physical_dispatches")
    metered = meter is not None
    values = list((meter or {}).values())
    unknown = sum(item.get("tokens") is None for item in values) if metered else None
    measured = None if unknown or not metered else sum(item["tokens"] for item in values)
    ledger = evidence["controller"]["accounting"]
    assert ledger["tokens"] == row["tokens"]
    assert not metered or len(meter) == row["requests"]
    assert not metered or measured == ledger["tokens"], (key, measured, ledger)
    assert digest(path) == row["evidence_sha256"]
    grade = evidence["confirmation_grade"]
    assert row["passed"] == bool(grade["passed"] and evidence["selected_grade"]["passed"])
    refinement = evidence.get("refinement") or {}
    promotion = evidence.get("promotion") or {}
    cause = path.parent / "refinement-cause.json"
    return {
        "task_id": key[0],
        "arm": key[1],
        "repetition": key[2],
        "source_evidence_bytes_sha256": digest(path),
        "original_status": evidence["original"]["status"],
        "original_finish_reason": evidence["original"]["finish_reason"],
        "selected_status": evidence["selected"]["status"],
        "selected_finish_reason": evidence["selected"]["finish_reason"],
        "original_public_grade": evidence["original_grade"],
        "selected_public_grade": evidence["selected_grade"],
        "selected_private_grade": grade,
        "all_attempt_public_grades": evidence["all_attempt_grades"],
        "physical_dispatches": meter,
        "physical_request_count": len(meter) if metered else None,
        "unknown_dispatch_usage": unknown,
        "meter_tokens": measured,
        "ledger_tokens": ledger["tokens"],
        "meter_matches_ledger": measured == ledger["tokens"] if metered else None,
        "reserved_requests": ledger["requests"],
        "learning_failure": evidence["learning_failure"],
        "incomplete_cause": json.loads(cause.read_text()) if cause.exists() else None,
        "refinement": {
            name: refinement.get(name)
            for name in (
                "sha256", "decision", "reason", "qualification", "selected_sha256",
                "original_profile_sha256", "control", "composition", "excluded",
            )
        },
        "candidates": [
            {"candidate_sha256": item.get("sha256"), "evaluations": item.get("evaluations")}
            for item in refinement.get("candidates", [])
        ],
        "promotion": {
            name: promotion.get(name) for name in ("sha256", "decision", "reason", "rollback")
        },
        "candidate_count": row.get("candidate_count", 0),
        "promotion_count": row.get("promotion_count", 0),
        "rollback_count": row.get("rollback_count", 0),
        "created_lesson_ids": evidence["created_lesson_ids"],
        "qualification_complete": row.get("qualification_complete", True),
    }


def total(episodes, key):
    values = [episode[key] for episode in episodes]
    return sum(values) if all(value is not None for value in values) else None


def project(root, output):
    report = json.loads((root / "report.json").read_text())
    rows = report["rows"] + report.get("warmup_rows", [])
    by_key = {(row["task_id"], row["arm"], row["repetition"]): row for row in rows}
    assert len(by_key) == len(rows)
    episodes = [project_episode(path, by_key) for path in sorted(root.glob("*/evidence.json"))]
    assert not by_key, by_key.keys()
    output.mkdir(parents=True, exist_ok=True)
    for name in ("registration.json", "plan.json", "report.json"):
        path = root / name
        if path.exists():
            shutil.copyfile(path, output / name)
    reconciled = [episode["meter_matches_ledger"] for episode in episodes]
    audit = {
        "schema_version": 1,
        "projection": "counts_and_content_free_provenance_no_transcripts_credentials_or_task_solutions",
        "runtime_revision": report.get("runtime", {}).get("revision"),
        "source_report_bytes_sha256": digest(root / "report.json"),
        "episodes": episodes,
        "total_physical_requests": total(episodes, "physical_request_count"),
        "total_ledger_tokens": total(episodes, "ledger_tokens"),
        "total_unknown_dispatch_usage": total(episodes, "unknown_dispatch_usage"),
        "total_tokens": total(episodes, "meter_tokens"),
        "all_meters_match_ledgers": (
            all(reconciled) if all(value is not None for value in reconciled) else None
        ),
        "incomplete_episodes": sum(not episode["qualification_complete"] for episode in episodes),
        "all_report_rows_match_evidence_hashes": True,
    }
    (output / "audit.json").write_text(json.dumps(audit, indent=2, sort_keys=True) + "\n")
    print(json.dumps({key: value for key, value in audit.items() if key != "episodes"}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    project(args.root, args.output)
