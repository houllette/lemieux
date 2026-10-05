#!/bin/sh
# Grader for contract-webhook-signature: every fixture file must be unchanged and the
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
verify README.md 796199510
verify config/webhooks.ini 3701605085
verify docs/WEBHOOKS.md 4177534808
verify lib/webhooks/config.sh 3931069279
verify lib/webhooks/deliver.sh 1693976508
verify lib/webhooks/headers.sh 3136504644
verify lib/webhooks/sign.sh 1797868929
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\163\150\141\061'
expect 2 '\170\055\150\157\157\153\055\163\151\147\156\141\164\165\162\145'
echo "report ok"
