#!/bin/sh
# Grader for callgraph-shell-sync-download: every fixture file must be unchanged and the
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
verify README.md 1228756496
verify bin/cli 1252427020
verify lib/commands.sh 3330832879
verify lib/net.sh 945566705
verify lib/retry.sh 1822430788
verify lib/sync.sh 4141969883
verify lib/transport.sh 3442357096
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\144\157\167\156\154\157\141\144\137\167\151\164\150\137\143\165\162\154'
expect 2 '\164\162\141\156\163\160\157\162\164\056\163\150'
echo "report ok"
