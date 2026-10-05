#!/bin/sh
# Grader for data-skip-level-manager: every fixture file must be unchanged and the
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
verify data/README.md 1061443552
verify data/departments.json 2440861684
verify data/employees.csv 3819983900
verify data/transfers.csv 2102360502
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\157\163\145\151'
echo "report ok"
