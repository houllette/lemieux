#!/bin/sh
# Grader: the exporter goes through the documented entry point (audit_emit,
# category export), the audit log has the exact compliance format, the
# library and tests are untouched, and the suite passes.
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
verify() {
  [ -f "$1" ] || fail "$1 is missing"
  actual=$(cksum < "$1" | awk '{print $1}')
  [ "$actual" = "$2" ] || fail "$1 was modified"
}
verify lib/audit.sh 3808038130
verify lib/records.sh 1590406195
verify tests/run.sh 698067716
verify docs/API.md 3325560708
verify data/sample.tsv 4193292914
[ -f bin/export ] || fail "bin/export is missing"
grep -q 'audit_emit' bin/export || fail "bin/export does not use audit_emit"
grep -Eq 'audit_(log|write)' bin/export && fail "bin/export calls a deprecated or internal audit function"
out=$(sh tests/run.sh 2>&1) || fail "tests/run.sh failed: $out"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf 'x9\tSolo Record\t1.00\n' > "$tmp/one.tsv"
AUDIT_LOG=$tmp/audit.log sh bin/export "$tmp/one.tsv" >/dev/null 2>&1 || fail "export of a one-record file failed"
[ "$(cat "$tmp/audit.log")" = "0001 export exported x9" ] || fail "audit line for a fresh log was: $(cat "$tmp/audit.log")"
echo "audit ok"
