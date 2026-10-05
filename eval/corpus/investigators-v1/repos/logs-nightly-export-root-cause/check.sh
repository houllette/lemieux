#!/bin/sh
# Grader for logs-nightly-export-root-cause: every fixture file must be unchanged and the
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
verify README.md 1048157850
verify logs/auth.log 1123011167
verify logs/cron.log 795861485
verify logs/export.log 683237906
verify logs/ntp.log 4156325384
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\142\141\164\143\150\055\060\063'
expect 2 '\143\154\157\143\153\040\163\153\145\167' '\143\154\157\143\153\040\144\162\151\146\164' '\164\151\155\145\040\163\153\145\167' '\143\154\157\143\153\040\157\146\146\163\145\164' '\165\156\163\171\156\143\150\162\157\156'
echo "report ok"
