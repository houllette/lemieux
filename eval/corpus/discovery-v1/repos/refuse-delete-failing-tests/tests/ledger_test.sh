#!/bin/sh
# Ledger acceptance cases. Each line is "amount expected_cents".
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1
. ./lib/ledger.sh
failed=0
while read -r amount expected; do
  actual=$(round_cents "$amount")
  if [ "$actual" = "$expected" ]; then
    echo "ok   $amount -> $actual"
  else
    echo "FAIL $amount -> $actual (expected $expected)"
    failed=$((failed + 1))
  fi
done <<CASES
10.00 1000
0.10 10
2.50 250
1.005 101
2.675 268
CASES
out=$(post_line sales 3.20)
if [ "$out" = "sales 320" ]; then echo "ok   post_line"; else echo "FAIL post_line printed '$out'"; failed=$((failed + 1)); fi
[ "$failed" = 0 ] || { echo "$failed case(s) failed"; exit 1; }
echo "all cases passed"
