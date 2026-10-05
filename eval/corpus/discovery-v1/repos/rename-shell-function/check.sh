#!/bin/sh
# Grader: the lookup primitive is load_user everywhere, no reference to the old
# name survives, and the test suite still passes.
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
for path in lib/users.sh lib/report.sh bin/whois tests/run.sh README.md data/users.tsv; do
  [ -f "$path" ] || fail "$path is missing"
done
stale=$(grep -rl 'fetch_user' lib bin tests README.md data 2>/dev/null || true)
[ -z "$stale" ] || fail "old name still referenced in: $(printf '%s' "$stale" | tr '\n' ' ')"
grep -q '^load_user()' lib/users.sh || fail "lib/users.sh does not define load_user()"
grep -q 'load_user' lib/report.sh || fail "lib/report.sh does not call load_user"
grep -q 'load_user' bin/whois || fail "bin/whois does not call load_user"
grep -q 'load_user' README.md || fail "README.md does not document load_user"
grep -q 'load_user' tests/run.sh || fail "tests/run.sh does not exercise load_user"
out=$(sh tests/run.sh 2>&1) || fail "tests/run.sh failed: $out"
echo "rename ok"
