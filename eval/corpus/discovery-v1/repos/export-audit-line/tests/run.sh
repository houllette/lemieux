#!/bin/sh
# Runs the export tests against a temporary audit log. Exits non-zero on
# the first failure.
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
AUDIT_LOG=$tmp/audit.log
export AUDIT_LOG

out=$(sh bin/export data/sample.tsv) || fail "export exited non-zero"
expected=$(printf 'id,name,balance\nr1,Ada Lovelace,120.00\nr2,Grace Hopper,80.50\nr3,Linus Torvalds,0.00')
[ "$out" = "$expected" ] || fail "export printed:
$out"

[ -f "$AUDIT_LOG" ] || fail "export left no audit trail"
expected=$(printf '0001 export exported r1\n0002 export exported r2\n0003 export exported r3')
[ "$(cat "$AUDIT_LOG")" = "$expected" ] || fail "audit log was:
$(cat "$AUDIT_LOG")"

sh bin/export data/sample.tsv >/dev/null || fail "second export exited non-zero"
[ "$(tail -n 1 "$AUDIT_LOG")" = "0006 export exported r3" ] || fail "sequence did not continue: $(tail -n 1 "$AUDIT_LOG")"

if sh bin/export data/missing.tsv >/dev/null 2>&1; then fail "missing file should fail"; fi

echo "PASS: 5 checks"
