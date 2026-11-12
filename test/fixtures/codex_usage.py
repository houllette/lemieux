"""Offline account RPC fixture: rejects any inference or managed-login method."""
import json
import os
import sys

assert os.path.realpath(os.environ["CODEX_HOME"]) == os.getcwd()
assert not os.path.exists(os.path.join(os.getcwd(), "auth.json"))
expected = iter(["initialize", "initialized", "account/login/start", "account/rateLimits/read"])
for line in sys.stdin:
    request = json.loads(line)
    method = request["method"]
    assert method == next(expected)
    if method == "initialized":
        continue
    if method == "initialize":
        assert request["params"]["capabilities"]["experimentalApi"] is True
        result = {}
    elif method == "account/login/start":
        assert request["params"]["type"] == "chatgptAuthTokens"
        assert set(request["params"]) == {"type", "accessToken", "chatgptAccountId"}
        result = {"type": "chatgptAuthTokens"}
    else:
        result = {"rateLimits": {
            "primary": {"usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1800000000},
            "secondary": {"usedPercent": 42, "windowDurationMins": 10080, "resetsAt": 1800400000},
        }}
    print(json.dumps({"id": request["id"], "result": result}), flush=True)
