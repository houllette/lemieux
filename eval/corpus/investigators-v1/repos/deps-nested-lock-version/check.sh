#!/bin/sh
# Grader for deps-nested-lock-version: every fixture file must be unchanged and the
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
verify README.md 1691111111
verify package-lock.json 72329832
verify package.json 3463084995
verify packages/api/package.json 2623615417
verify packages/api/src/index.js 584651512
verify packages/web/package.json 272282051
verify packages/web/src/index.js 1313163432
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\061\056\062\056\071'
expect 2 '\061\056\063\056\062'
echo "report ok"
