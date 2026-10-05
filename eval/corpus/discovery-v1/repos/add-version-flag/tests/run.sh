#!/bin/sh
# Runs the tidy tests. Exits non-zero on the first failure.
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf 'one  \ntwo\nthree\t\n' > "$tmp/notes.txt"

if sh bin/tidy --check "$tmp/notes.txt" >/dev/null; then fail "--check should exit 1 on a dirty file"; fi
out=$(sh bin/tidy "$tmp/notes.txt") || fail "tidy exited non-zero"
[ "$out" = "$tmp/notes.txt: tidied 2 line(s)" ] || fail "tidy printed '$out'"
[ "$(cat "$tmp/notes.txt")" = "$(printf 'one\ntwo\nthree')" ] || fail "file was not tidied"
sh bin/tidy --check --quiet "$tmp/notes.txt" || fail "--check should exit 0 on a clean file"
if sh bin/tidy --bogus "$tmp/notes.txt" >/dev/null 2>&1; then fail "unknown option should be rejected"; fi

echo "PASS: 5 checks"
