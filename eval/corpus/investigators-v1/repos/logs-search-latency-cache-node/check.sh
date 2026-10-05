#!/bin/sh
# Grader for logs-search-latency-cache-node: every fixture file must be unchanged and the
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
verify README.md 2940201851
verify logs/access.log 2148202019
verify logs/app.log 193558350
verify logs/cache.log 2846849371
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\143\141\143\150\145\055\142'
expect 2 '\162\145\163\164\141\162\164' '\157\165\164\040\157\146\040\155\145\155\157\162\171' '\157\157\155'
echo "report ok"
