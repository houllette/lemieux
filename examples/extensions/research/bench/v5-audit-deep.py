"""Arm-blind claim audit against fetched cited pages, with uncertain cases retained."""
import json
import re
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent.parent
blind = json.loads((ROOT / "tmp/research-v5-blind.json").read_text())
corpus = json.loads((ROOT / "bench/v5-corpus.json").read_text())
claims_by_task = {t["id"]: {c["id"]: c for c in t["claims"]} for t in corpus["tasks"]}
rows = json.loads((ROOT / "tmp/research-v5-source-preflight.json").read_text())["rows"]
rows += json.loads((ROOT / "tmp/research-v5-audit-fetch.json").read_text())["rows"]
texts = {r["url"]: (ROOT / r["path"]).read_text() for r in rows if not r["error"]}
PRIMARY = {"go.dev", "blog.rust-lang.org", "doc.rust-lang.org", "rust.docs.kernel.org",
           "nodejs.org", "beta.docs.nodejs.org", "kubernetes.io"}


def primary(url):
    host = urlparse(url).hostname or ""
    return host in PRIMARY or host == "github.com" and urlparse(url).path.startswith("/golang/go/")


audit = []
for record in blind:
    entries = []
    for claim in record["claims"]:
        if not claim["answer_pattern_match"]:
            entries.append({"id": claim["id"], "status": "absent_by_proxy", "supporting_urls": []})
            continue
        pattern = claims_by_task[record["task_id"]][claim["id"]]["pattern"]
        matches = []
        for url in record["citations"]:
            if url not in record["fetched_urls"] or url not in texts:
                continue
            hit = re.search(pattern, texts[url])
            if hit:
                matches.append({"url": url, "primary": primary(url),
                                "excerpt": texts[url][max(0, hit.start()-100): min(len(texts[url]),hit.end()+100)].replace("\n", " ")})
        status = "supported_primary" if any(m["primary"] for m in matches) else (
            "supported_secondary_only" if matches else "unresolved")
        entries.append({"id": claim["id"], "status": status, "supporting_urls": matches})
    audit.append({"id": record["id"], "task_id": record["task_id"], "claims": entries})
(ROOT / "tmp/research-v5-deep-audit.json").write_text(json.dumps(audit, indent=2) + "\n")
from collections import Counter
print(Counter(c["status"] for row in audit for c in row["claims"]))
print("all supported primary",sum(all(c["status"]=="supported_primary" for c in row["claims"]) for row in audit))
