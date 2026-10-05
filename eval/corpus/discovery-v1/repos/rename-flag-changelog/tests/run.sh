#!/bin/sh
# Runs the deploy tests. Exits non-zero on the first failure.
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

out=$(sh bin/deploy staging) || fail "deploy staging exited non-zero"
[ "$out" = "deploying build to staging" ] || fail "deploy staging printed '$out'"

out=$(sh bin/deploy production --dry-run) || fail "dry run exited non-zero"
[ "$out" = "would deploy build to production" ] || fail "dry run printed '$out'"

if sh bin/deploy staging --bogus >/dev/null 2>&1; then fail "unknown option should be rejected"; fi
if sh bin/deploy sandbox >/dev/null 2>&1; then fail "unknown environment should be rejected"; fi

echo "PASS: 4 checks"
