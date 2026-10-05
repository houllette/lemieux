#!/bin/sh
# Grader for logs-error-reference-query: every fixture file must be unchanged and the
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
verify README.md 468826988
verify logs/db.log 2215413404
verify logs/gateway.log 151910908
verify logs/web-1.log 56640692
verify logs/web-2.log 1176218803
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\163\165\155\155\141\162\171\137\142\171\137\155\157\156\164\150'
expect 2 '\167\145\142\055\062'
echo "report ok"
