#!/bin/sh
# Grader: the checks and the tests are untouched, and the suite passes
# (correct exit status, prefixed output and summary in every scenario).
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
verify() {
  [ -f "$1" ] || fail "$1 is missing"
  actual=$(cksum < "$1" | awk '{print $1}')
  [ "$actual" = "$2" ] || fail "$1 was modified"
}
verify checks/10-whitespace.sh 1814913727
verify checks/20-title.sh 3009677325
verify checks/30-size.sh 2637272231
verify tests/run.sh 2544825565
[ -f run-checks.sh ] || fail "run-checks.sh is missing"
head -n 1 run-checks.sh | grep -q '^#!/bin/sh$' || fail "run-checks.sh must stay a POSIX sh script"
out=$(sh tests/run.sh 2>&1) || fail "tests/run.sh failed: $out"
echo "checks ok"
