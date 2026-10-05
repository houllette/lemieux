#!/bin/sh
# Grader for logs-lockout-device: every fixture file must be unchanged and the
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
verify README.md 2617551448
verify logs/auth.log 3198395207
verify logs/dhcp.log 2366607827
verify logs/vpn.log 3218135101
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\167\163\055\157\160\163\055\061\062'
echo "report ok"
