"""Regenerate the investigators-v2 corpus.

    python3 eval/corpus/investigators-v2/generators/build.py

Writes repos/<id>/ (fixture plus check.sh), answers/<id>.txt and
manifest.json. Every generator is seeded, so the output is byte-identical
across runs; README.md is hand-written and left alone.
"""

from __future__ import annotations

import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import common  # noqa: E402
import gen_call_graph  # noqa: E402
import gen_config_layering  # noqa: E402
import gen_data_join  # noqa: E402
import gen_deps_build  # noqa: E402
import gen_docs_vs_code  # noqa: E402
import gen_log_join  # noqa: E402

GENERATORS = [gen_log_join, gen_config_layering, gen_call_graph, gen_data_join, gen_deps_build, gen_docs_vs_code]


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    for sub in ("repos", "answers"):
        path = os.path.join(root, sub)
        if os.path.isdir(path):
            shutil.rmtree(path)
        os.makedirs(path)
    tasks, clusters = [], []
    for module in GENERATORS:
        for case in module.cases():
            tasks.append(common.emit(case, root))
            if case.cluster not in clusters:
                clusters.append(case.cluster)
            print("%-42s %4d files %7d bytes" % (case.id, len(case.files), case.total_bytes()))
    manifest = {
        "version": 1,
        "metadata": {
            "suite": "lemieux-investigators-v2",
            "description": "Read-only investigation questions over fixtures too large to read in one tool call: logs joined through inventories, deep configuration layering, "
                           "large call graphs, sharded data joins, fictional dependency and build trees, and documentation that disagrees with code. Built for the read-only "
                           "investigator (delegate) evaluation after investigators-v1 tied on both arms.",
            "tools": ["read", "bash"],
            "clusters": sorted(clusters),
        },
        "tasks": tasks,
    }
    with open(os.path.join(root, "manifest.json"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(common.dump_json(manifest))
    total = sum(t["metadata"]["fixture_bytes"] for t in tasks)
    print("%d cases, %d bytes" % (len(tasks), total))


if __name__ == "__main__":
    main()
