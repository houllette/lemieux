#!/bin/sh
# Grader for deps-pip-constraint-conflict: every fixture file must be unchanged and the
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
verify README.md 4036886970
verify constraints.txt 2957794329
verify pyproject.toml 1229804781
verify requirements.txt 2447536053
verify requirements/base.txt 1883578395
verify requirements/dev.txt 749537145
verify requirements/prod.txt 859086588
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\165\162\154\154\151\142\063'
expect 2 '\143\157\156\163\164\162\141\151\156\164\163\056\164\170\164'
expect 3 '\160\162\157\144\056\164\170\164'
echo "report ok"
