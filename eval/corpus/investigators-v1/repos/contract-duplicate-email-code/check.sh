#!/bin/sh
# Grader for contract-duplicate-email-code: every fixture file must be unchanged and the
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
verify README.md 216941125
verify api/app.py 1904610668
verify api/errors.py 3065866227
verify api/repo.py 807779085
verify api/users.py 1492295932
verify docs/API.md 3537433552
verify tests/test_users.py 2688049671
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\145\155\141\151\154\137\164\141\153\145\156'
echo "report ok"
