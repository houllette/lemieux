#!/usr/bin/env python3
"""Ordered raw JSON-RPC replies for MCP client failure and pagination tests.

The journal is written before each reply so a completed call can assert the
requests actually sent over stdin. Exhausted or unexpected scripts fail with
a reply, rather than leaving a broken pagination test hanging indefinitely.
"""

import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    steps = iter(json.load(source))

for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request:
        continue
    with open(sys.argv[2], "a", encoding="utf-8") as journal:
        journal.write(json.dumps(request) + "\n")

    step = next(steps, None)
    params = {k: v for k, v in request.get("params", {}).items() if k != "_meta"}
    matches = (step is not None and request.get("method") == step["method"]
               and params == step.get("params", {}))
    if not matches:
        reply = {"error": {"code": -32603, "message": "unexpected scripted request"}}
    elif step.get("close"):
        break
    else:
        reply = step["reply"]

    response = {"jsonrpc": "2.0", "id": request["id"], **reply}
    print(json.dumps(response), flush=True)
