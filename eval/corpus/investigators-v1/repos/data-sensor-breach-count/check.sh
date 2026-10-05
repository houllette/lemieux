#!/bin/sh
# Grader for data-sensor-breach-count: every fixture file must be unchanged and the
# reported answer (argv 1) must contain each expected fact.
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
answer=$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')
verify() {
  [ -f "$1" ] || fail "$1 is missing"
  actual=$(cksum < "$1" | awk '{print $1}')
  [ "$actual" = "$2" ] || fail "$1 was modified"
}
expect() {
  label=$1; shift
  for enc in "$@"; do
    tok=$(printf "$enc")
    case "$answer" in *"$tok"*) return 0 ;; esac
  done
  fail "answer is missing expected fact $label"
}
verify data/README.md 4160806568
verify data/readings-day1.csv 1875425322
verify data/readings-day2.csv 431967284
verify data/sensors.json 2003363660
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\154\157\141\144\151\156\147\055\144\157\143\153'
expect 2 '\066\040\164\151\155\145\163' '\163\151\170\040\164\151\155\145\163' '\066\040\142\162\145\141\143\150' '\163\151\170\040\142\162\145\141\143\150' '\040\066\040' '\050\066\051' '\066\040\162\145\141\144\151\156\147\163' '\066\040\145\170\143\145\145\144' '\143\157\165\156\164\040\157\146\040\066' '\164\157\164\141\154\040\157\146\040\066' '\075\040\066'
echo "report ok"
