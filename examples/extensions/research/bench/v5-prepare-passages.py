"""Freeze a question-only passage selector over the guarded source snapshots."""
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
corpus = json.loads((ROOT / "bench/v5-corpus.json").read_text())
rows = json.loads((ROOT / "tmp/research-v5-source-preflight.json").read_text())["rows"]
texts = {row["url"]: (ROOT / row["path"]).read_text() for row in rows if not row["error"]}
STOP = set("about after also and are because been both can check cite current describe each explain first from give into its later more name need note official only over page part project release same say source state team that their them then there this those using version what when where which while with would your".split())


def terms(question):
    return {word.lower() for word in re.findall(r"[A-Za-z][A-Za-z0-9_.:/-]{3,}", question)
            if word.lower() not in STOP}


def select(text, question, cap=6000):
    if len(text) <= cap:
        return text
    keys = terms(question)
    windows = []
    for start in range(0, len(text), 800):
        window = text[start:start + 1000]
        lower = window.lower()
        score = sum((2 if any(c.isdigit() for c in key) else 1) for key in keys if key in lower)
        windows.append((score, start, window))
    ranked = sorted(windows, key=lambda row: (-row[0], row[1]))
    chosen = []
    for score, start, window in ranked:
        if any(abs(start - old_start) < 800 for _, old_start, _ in chosen):
            continue
        chosen.append((score, start, window))
        if len(chosen) == 6:
            break
    return "\n[passage break]\n".join(window for _, _, window in sorted(chosen, key=lambda row: row[1]))[:cap]


outputs = []
for task in corpus["tasks"]:
    urls = list(dict.fromkeys(claim["source"] for claim in task["claims"]))
    full = [{"url": url, "text": texts[url]} for url in urls]
    selected = [{"url": url, "text": select(texts[url], task["prompt"])} for url in urls]
    preserved = sum(bool(re.search(claim["pattern"], next(page["text"] for page in selected if page["url"] == claim["source"]))) for claim in task["claims"])
    outputs.append({"id": task["id"], "prompt": task["prompt"], "full": full, "selected": selected,
                    "claim_patterns_in_selected": preserved, "claim_count": len(task["claims"])})
out = ROOT / "tmp/research-v5-synthesis-inputs.json"
out.write_text(json.dumps(outputs, indent=2) + "\n")
print(out, "sha256", hashlib.sha256(out.read_bytes()).hexdigest())
for row in outputs:
    print(row["id"], "selected claim patterns", row["claim_patterns_in_selected"], "/", row["claim_count"],
          "characters", sum(len(p["text"]) for p in row["full"]), "->", sum(len(p["text"]) for p in row["selected"]))
