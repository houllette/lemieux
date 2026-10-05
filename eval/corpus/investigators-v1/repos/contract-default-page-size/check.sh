#!/bin/sh
# Grader for contract-default-page-size: every fixture file must be unchanged and the
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
verify README.md 2693033331
verify api/constants.py 1355386831
verify api/items.py 870489146
verify api/pagination.py 79390915
verify api/repo.py 718667222
verify api/settings.py 4079034957
verify config/limits.toml 2901955386
verify docs/API.md 2147801845
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\061\065'
echo "report ok"
