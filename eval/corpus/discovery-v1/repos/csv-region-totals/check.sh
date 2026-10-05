#!/bin/sh
# Grader: out/totals.csv must match the report specification in data/README.md
# exactly (the expected content is kept as a checksum so the answer cannot be
# read out of this script), and the source export must be untouched.
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
[ -f data/sales.csv ] || fail "data/sales.csv is missing"
[ "$(cksum < data/sales.csv | awk '{print $1}')" = "509756754" ] || fail "data/sales.csv was modified"
[ -f out/totals.csv ] || fail "out/totals.csv is missing"
content=$(cat out/totals.csv)
digest=$(printf '%s\n' "$content" | cksum | awk '{print $1}')
[ "$digest" = "889052293" ] || fail "out/totals.csv does not match the specification; content was:
$content"
echo "totals ok"
