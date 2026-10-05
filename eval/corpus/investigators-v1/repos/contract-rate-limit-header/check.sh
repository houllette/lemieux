#!/bin/sh
# Grader for contract-rate-limit-header: every fixture file must be unchanged and the
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
verify README.md 2539943288
verify config/headers.json 1122762450
verify docs/API.md 1688650490
verify middleware/__init__.py 105354330
verify middleware/buckets.py 1978070354
verify middleware/ratelimit.py 3881637918
verify middleware/requestid.py 1222802835
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\170\055\162\141\164\145\154\151\155\151\164\055\162\145\163\145\164'
expect 2 '\155\151\154\154\151\163\145\143\157\156\144' '\040\155\163' '\050\155\163'
echo "report ok"
