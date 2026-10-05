#!/bin/sh
# Grader for callgraph-make-deploy-uploader: every fixture file must be unchanged and the
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
verify Makefile 1737521798
verify README.md 3208493229
verify deploy/target.env 925172
verify deploy/target.example.env 3560284355
verify scripts/build.sh 3314040479
verify scripts/deploy.sh 1248330080
verify scripts/lib/common.sh 3759279997
verify scripts/lib/registry.sh 247230211
verify scripts/lib/storage.sh 2946992626
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\165\160\154\157\141\144\137\147\143\163'
expect 2 '\163\164\157\162\141\147\145\056\163\150'
echo "report ok"
