import json, hashlib
from pathlib import Path
root=Path("tmp/feedback-calibration-live")
report_path=root/"report.json"
if not report_path.exists():
    raise SystemExit("Calibration report pending; no selection made")
report=json.loads(report_path.read_text())
assert report["execution_complete"] is True, "Incomplete calibration cannot select a stream"
assert report["unknown_token_rows"] == 0, "Unknown usage closes admission"
assert all(row["safety_failures"] == [] for row in report["rows"]), "Unsafe calibration closes admission"
records={}
for path in root.glob("*/evidence.json"):
    ev=json.loads(path.read_text())
    context=ev["context"]
    if context["arm"] in ["disabled","reference"]:
        records[(context["task"]["id"],context["arm"])]=(ev,path)
rows={(r["task_id"],r["arm"]):r for r in report["rows"]}
eligible=[]
decisions=[]
for task in json.loads((root/"plan.json").read_text())["tasks"]:
    task_id=task["id"]
    if task_id not in ["hgrecco-pint-948-public-v3"]:
        continue
    checks={}
    for arm in ["disabled","reference"]:
        ev,path=records[(task_id,arm)]
        row=rows[(task_id,arm)]
        observation=ev["original"]
        grade=ev["original_grade"]
        usage=observation.get("usage") or {}
        checks[arm]={
            "completed":observation.get("status")=="completed",
            "no_provider_error":observation.get("provider_error") is None,
            "known_tokens":all(type(usage.get(k)) is int and usage[k]>=0 for k in ["input_tokens","output_tokens"]),
            "safe":grade.get("safety_failures")==[],
            "public_passed":grade.get("passed"),
            "qualification_complete":row["qualification_complete"],
            "source_evidence_bytes_sha256":hashlib.sha256(path.read_bytes()).hexdigest()
        }
    valid=lambda c:all(c[k] for k in ["completed","no_provider_error","known_tokens","safe","qualification_complete"])
    yes=valid(checks["disabled"]) and valid(checks["reference"]) and checks["disabled"]["public_passed"] is False and checks["reference"]["public_passed"] is True
    if yes:eligible.append(task_id)
    decisions.append({"task_id":task_id,"cluster":task["cluster"],"eligible":yes,"checks":checks})
result={"kind":"preregistered_calibration_selection/v1","calibration_report_bytes_sha256":hashlib.sha256(report_path.read_bytes()).hexdigest(),"private_confirmation_used_for_selection":False,"eligible_targets":sorted(eligible),"selected_target":min(eligible) if eligible else None,"fixed_seed":"hgrecco-pint-652","decisions":decisions}
Path("tmp/feedback-calibration-selection.json").write_text(json.dumps(result,indent=2,sort_keys=True)+"\n")
print(json.dumps({k:v for k,v in result.items() if k!="decisions"},indent=2))
