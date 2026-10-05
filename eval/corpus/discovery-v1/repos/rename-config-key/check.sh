#!/bin/sh
# Grader: the key is retry_limit in the config, the script, the docs and the
# tests, nothing still reads max_retries, and the suite passes.
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
for path in worker.conf bin/worker.sh docs/CONFIG.md tests/run.sh; do
  [ -f "$path" ] || fail "$path is missing"
done
stale=$(grep -rl 'max_retries' worker.conf bin docs tests 2>/dev/null || true)
[ -z "$stale" ] || fail "old key still referenced in: $(printf '%s' "$stale" | tr '\n' ' ')"
grep -q '^retry_limit=5$' worker.conf || fail "worker.conf does not set retry_limit=5"
grep -q 'retry_limit' bin/worker.sh || fail "bin/worker.sh does not read retry_limit"
grep -q 'retry_limit' docs/CONFIG.md || fail "docs/CONFIG.md does not document retry_limit"
grep -q 'retry_limit' tests/run.sh || fail "tests/run.sh does not use retry_limit"
out=$(sh tests/run.sh 2>&1) || fail "tests/run.sh failed: $out"
echo "rename ok"
