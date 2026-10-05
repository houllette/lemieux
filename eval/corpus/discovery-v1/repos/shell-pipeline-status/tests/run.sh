#!/bin/sh
# Runs the run-checks tests. Exits non-zero on the first failure.
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir "$tmp/clean"
printf '# Clean\n\nAll good.\n' > "$tmp/clean/a.md"
out=$(sh run-checks.sh "$tmp/clean" 2>&1); status=$?
[ "$status" = 0 ] || fail "clean directory: exit $status, output:
$out"
[ "$out" = "$(printf '[10-whitespace] ok\n[20-title] ok\n[30-size] ok\nall 3 checks passed')" ] || fail "clean directory printed:
$out"

mkdir "$tmp/one"
printf '# Sloppy\n\ntrailing space here \n' > "$tmp/one/b.md"
out=$(sh run-checks.sh "$tmp/one" 2>&1); status=$?
[ "$status" = 1 ] || fail "one failing check: exit $status, expected 1"
printf '%s\n' "$out" | grep -q '^\[10-whitespace\] trailing whitespace: b.md$' || fail "failure line not prefixed:
$out"
[ "$(printf '%s\n' "$out" | tail -n 1)" = "1 of 3 checks failed" ] || fail "one failing check summary was:
$(printf '%s\n' "$out" | tail -n 1)"

mkdir "$tmp/two"
printf 'No title here \n' > "$tmp/two/c.md"
out=$(sh run-checks.sh "$tmp/two" 2>&1); status=$?
[ "$status" = 1 ] || fail "two failing checks: exit $status, expected 1"
[ "$(printf '%s\n' "$out" | tail -n 1)" = "2 of 3 checks failed" ] || fail "two failing checks summary was:
$(printf '%s\n' "$out" | tail -n 1)"

if sh run-checks.sh "$tmp/nope" >/dev/null 2>&1; then fail "missing directory should fail"; fi

echo "PASS: 4 scenarios"
