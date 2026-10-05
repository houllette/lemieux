#!/bin/sh
# Grader: out/stock.csv must match the specification in data/README.md exactly
# (kept as a checksum so the answer cannot be read out of this script), and
# both exports must be untouched.
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
[ -f data/warehouse_a.csv ] || fail "data/warehouse_a.csv is missing"
[ -f data/warehouse_b.csv ] || fail "data/warehouse_b.csv is missing"
[ "$(cksum < data/warehouse_a.csv | awk '{print $1}')" = "1827451749" ] || fail "data/warehouse_a.csv was modified"
[ "$(cksum < data/warehouse_b.csv | awk '{print $1}')" = "423629788" ] || fail "data/warehouse_b.csv was modified"
[ -f out/stock.csv ] || fail "out/stock.csv is missing"
content=$(cat out/stock.csv)
digest=$(printf '%s\n' "$content" | cksum | awk '{print $1}')
[ "$digest" = "3260646966" ] || fail "out/stock.csv does not match the specification; content was:
$content"
echo "stock ok"
