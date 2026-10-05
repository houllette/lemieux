#!/bin/sh
# Grader: the source table carries both new codes, the committed generated
# file is exactly what the untouched generator produces from that source, and
# the suite passes.
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
for path in src/status_codes.tsv scripts/gen.sh lib/status_codes.sh bin/status tests/run.sh; do
  [ -f "$path" ] || fail "$path is missing"
done
[ "$(cksum < scripts/gen.sh | awk '{print $1}')" = "3813527807" ] || fail "scripts/gen.sh was modified"
[ "$(cksum < tests/run.sh | awk '{print $1}')" = "78028667" ] || fail "tests/run.sh was modified"
grep -q "$(printf '^422\tUnprocessable Content$')" src/status_codes.tsv || fail "src/status_codes.tsv has no 422 row"
grep -q "$(printf '^429\tToo Many Requests$')" src/status_codes.tsv || fail "src/status_codes.tsv has no 429 row"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp -R src scripts lib "$tmp/"
(cd "$tmp" && sh scripts/gen.sh >/dev/null 2>&1) || fail "scripts/gen.sh failed on the source table"
cmp -s "$tmp/lib/status_codes.sh" lib/status_codes.sh || fail "lib/status_codes.sh is not what scripts/gen.sh produces from src/status_codes.tsv"
out=$(sh tests/run.sh 2>&1) || fail "tests/run.sh failed: $out"
echo "table ok"
