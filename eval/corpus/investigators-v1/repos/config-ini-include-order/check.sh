#!/bin/sh
# Grader for config-ini-include-order: every fixture file must be unchanged and the
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
verify README.md 4292436871
verify app.ini 1321664821
verify conf.d/05-legacy.ini 835587819
verify conf.d/10-base.ini 3346088119
verify conf.d/20-cache.ini 3244776936
verify conf.d/30-cache.ini.disabled 204733383
verify conf.d/README 3265803285
verify docs/INI.md 1706546940
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\071\060\060'
expect 2 '\062\060\055\143\141\143\150\145\056\151\156\151'
echo "report ok"
