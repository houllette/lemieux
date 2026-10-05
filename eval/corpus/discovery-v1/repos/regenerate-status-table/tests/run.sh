#!/bin/sh
# Runs the status tests. Exits non-zero on the first failure.
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
expect() {
  out=$(sh bin/status "$1" 2>&1) || fail "status $1 exited non-zero: $out"
  [ "$out" = "$2" ] || fail "status $1 printed '$out'"
}
expect 200 "OK"
expect 404 "Not Found"
expect 422 "Unprocessable Content"
expect 429 "Too Many Requests"
expect 503 "Service Unavailable"
if sh bin/status 999 >/dev/null 2>&1; then fail "unknown code should fail"; fi
echo "PASS: 6 checks"
