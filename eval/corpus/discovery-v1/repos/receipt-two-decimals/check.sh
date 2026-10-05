#!/bin/sh
# Grader: the test suite passes unchanged, and both renderers print two
# decimals when driven directly (so a suite that was quietly loosened cannot
# pass on its own).
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
verify() {
  [ -f "$1" ] || fail "$1 is missing"
  actual=$(cksum < "$1" | awk '{print $1}')
  [ "$actual" = "$2" ] || fail "$1 was modified"
}
verify tests/test_receipt.py 2625218016
verify tests/test_summary.py 1923557998
verify tests/run.sh 3913303934
out=$(sh tests/run.sh 2>&1) || fail "tests/run.sh failed:
$out"
out=$(PYTHONDONTWRITEBYTECODE=1 python3 -c 'from lib.receipt import render_receipt; print(render_receipt([("Tea", 180), ("Scone", 320)]))' 2>&1) || fail "receipt renderer crashed: $out"
[ "$out" = "$(printf 'Tea             1.80\nScone           3.20\nTOTAL           5.00')" ] || fail "receipt printed:
$out"
out=$(PYTHONDONTWRITEBYTECODE=1 python3 -c 'from lib.summary import render_summary; print(render_summary([("2026-09-10", [110, 90]), ("2026-09-11", [5])]))' 2>&1) || fail "summary renderer crashed: $out"
[ "$out" = "$(printf '2026-09-10 2.00\n2026-09-11 0.05')" ] || fail "summary printed:
$out"
echo "amounts ok"
