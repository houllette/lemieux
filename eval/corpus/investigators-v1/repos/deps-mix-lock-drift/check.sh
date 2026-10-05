#!/bin/sh
# Grader for deps-mix-lock-drift: every fixture file must be unchanged and the
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
verify CHANGELOG.md 1420821471
verify README.md 3430649279
verify apps/core/mix.exs 3668596388
verify apps/web/mix.exs 2795810795
verify mix.exs 3942559388
verify mix.lock 483745415
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\164\145\154\145\155\145\164\162\171'
expect 2 '\060\056\064\056\063'
echo "report ok"
