#!/bin/sh
# Grader for deps-go-workspace-replace: every fixture file must be unchanged and the
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
verify README.md 3253382136
verify cmd/proxy/main.go 3164346884
verify docs/BUILD.md 1022987156
verify forks/ratelimit-fast/VERSION 2433118133
verify forks/ratelimit-fast/go.mod 567661154
verify go.mod 1614027856
verify go.sum 1047673394
verify go.work 254759595
verify tools/go.mod 1155364078
verify vendor-local/ratelimit/VERSION 1826703024
verify vendor-local/ratelimit/go.mod 567661154
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\061\056\064\056\063\055\146\141\163\164'
expect 2 '\146\157\162\153\163\057\162\141\164\145\154\151\155\151\164\055\146\141\163\164'
echo "report ok"
