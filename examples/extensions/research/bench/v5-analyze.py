"""Create arm-blind claim worksheets and a request ledger from the frozen v5 run.

The worksheet is a review aid: regex completion and designated-source matches
are not a semantic entailment judge. Keep raw answers/transcripts under tmp/.
"""
import hashlib
import json
import random
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CORPUS = json.loads((ROOT / "bench/v5-corpus.json").read_text())
REPORT = json.loads((ROOT / "tmp/research-v5-report.json").read_text())
SOURCES = json.loads((ROOT / "tmp/research-v5-source-preflight.json").read_text())
TEXT = {row["url"]: Path(ROOT / row["path"]).read_text() for row in SOURCES["rows"] if not row["error"]}
TASKS = {task["id"]: task for task in CORPUS["tasks"]}


def answer_and_citations(result):
    observation = result.get("observation") or {}
    raw = observation.get("answer") or ""
    citations = observation.get("citations") or []
    try:
        parsed = json.loads(raw)
        if isinstance(parsed, dict) and isinstance(parsed.get("answer"), str):
            raw = parsed["answer"]
            citations = parsed.get("citations") or citations
    except (json.JSONDecodeError, TypeError):
        pass
    return raw, [url for url in citations if isinstance(url, str)]


def page_urls(result):
    observation = result.get("observation") or {}
    urls = [page["url"] for page in observation.get("fetched") or []]
    for event in observation.get("transcript") or []:
        if event.get("type") == "tool_result":
            payload = event.get("payload") or {}
            if payload.get("name") == "web_fetch" and payload.get("outcome") == "success":
                urls.append((payload.get("arguments") or {}).get("url"))
                urls.append((payload.get("structured_content") or {}).get("url"))
    return [url for url in urls if isinstance(url, str)]


def counts(result):
    arm = result["runtime"]
    observation = result.get("observation") or {}
    resources = observation.get("resources") or {}
    fetched = observation.get("fetched") or []
    skipped = observation.get("skipped") or []
    discovery = observation.get("discovery") or {}
    if arm == "model-alone":
        searches = fetches = classifiers = denied = 0
        fetched_bytes = 0
    elif arm == "iterative-web":
        calls = [event.get("payload") or {} for event in observation.get("transcript") or [] if event.get("type") == "tool_result"]
        searches = sum(call.get("name") == "web_search" and call.get("outcome") != "denied" for call in calls)
        fetches = sum(call.get("name") == "web_fetch" and call.get("outcome") != "denied" for call in calls)
        classifiers = 0
        denied = sum(call.get("outcome") == "denied" for call in calls)
        fetched_bytes = sum((call.get("structured_content") or {}).get("bytes") or 0 for call in calls if call.get("name") == "web_fetch")
    else:
        searches = 1
        fetches = discovery.get("attempts") if arm == "jev-guided" else len(fetched) + sum("budget" not in row.get("reason", "") for row in skipped)
        classifiers = discovery.get("classifier_attempts") if arm == "jev-guided" else 0
        denied = 0
        fetched_bytes = sum(page.get("bytes") or 0 for page in fetched)
    return {"model_requests": resources.get("requests"), "classifier_requests": classifiers,
            "search_requests": searches, "fetch_requests": fetches, "denied_calls": denied,
            "fetched_body_bytes": fetched_bytes, "input_tokens": resources.get("full_input_tokens"),
            "output_tokens": resources.get("output_tokens"), "model_cost_usd": resources.get("cost_usd")}


rng = random.Random(20260928)
records = []
for result in REPORT["results"]:
    answer, citations = answer_and_citations(result)
    fetched_urls = page_urls(result)
    claims = []
    for claim in TASKS[result["task_id"]]["claims"]:
        answer_match = bool(re.search(claim["pattern"], answer))
        source_text = TEXT.get(claim["source"], "")
        match = re.search(claim["pattern"], source_text)
        excerpt = source_text[max(0, match.start() - 90): min(len(source_text), match.end() + 90)].replace("\n", " ") if match else None
        source_cited = claim["source"] in citations
        source_fetched = claim["source"] in fetched_urls
        claims.append({"id": claim["id"], "answer_pattern_match": answer_match,
                       "designated_source": claim["source"], "designated_source_cited": source_cited,
                       "designated_source_fetched": source_fetched,
                       "source_pattern_match": bool(match), "source_excerpt": excerpt,
                       "review": "claim support and attribution require semantic review" if answer_match else "claim absent by proxy"})
    records.append({"task_id": result["task_id"], "arm": result["runtime"], "answer": answer,
                    "citations": citations, "fetched_urls": fetched_urls, "claims": claims,
                    "grader_passed_original": result.get("passed"),
                    "frozen_proxy_passed": all(claim["answer_pattern_match"] for claim in claims), "status": (result.get("observation") or {}).get("status"),
                    "counts": counts(result)})
rng.shuffle(records)
blind = []
key = []
for index, record in enumerate(records, 1):
    anon = f"B{index:03d}"
    key.append({"id": anon, "task_id": record["task_id"], "arm": record["arm"]})
    blind.append({"id": anon, **{field: value for field, value in record.items() if field not in ("arm", "counts", "grader_passed_original")}})
(ROOT / "tmp/research-v5-blind.json").write_text(json.dumps(blind, indent=2) + "\n")
(ROOT / "tmp/research-v5-blind-key.json").write_text(json.dumps(key, indent=2) + "\n")
(ROOT / "tmp/research-v5-ledger.json").write_text(json.dumps(records, indent=2) + "\n")
print("attempts", len(records), "claims", sum(len(row["claims"]) for row in records))
for arm in ("model-alone", "one-search-fetch", "jev-guided", "iterative-web"):
    group = [row for row in records if row["arm"] == arm]
    print(arm, "pass", sum(row["frozen_proxy_passed"] for row in group),
          "claim matches", sum(c["answer_pattern_match"] for row in group for c in row["claims"]),
          "requests", {field: sum(row["counts"][field] or 0 for row in group) for field in ("model_requests", "classifier_requests", "search_requests", "fetch_requests")})
