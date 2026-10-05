#!/bin/sh
# Grader for contract-cli-exit-status: every fixture file must be unchanged and the
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
verify README.md 2051662794
verify bin/sync 248222720
verify docs/CLI.md 3889367938
verify lib/codes.local.sh 1138674270
verify lib/codes.sh 2319484151
verify lib/exit.sh 2393649886
verify lib/sync.sh 447768260
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\067\065'
echo "report ok"
