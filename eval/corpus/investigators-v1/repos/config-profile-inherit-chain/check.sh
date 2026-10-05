#!/bin/sh
# Grader for config-profile-inherit-chain: every fixture file must be unchanged and the
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
verify README.md 709227745
verify config/defaults.toml 1163274307
verify config/profiles/web-eu.toml 3935687885
verify config/profiles/web-hot.toml 1628794916
verify config/profiles/web.toml 1636691453
verify config/profiles/worker.toml 4259819524
verify deploy/eu.env 3613120845
verify deploy/us.env 1956175072
verify docs/CONFIGURATION.md 2748269290
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\063\062'
expect 2 '\167\145\142\055\150\157\164\056\164\157\155\154'
echo "report ok"
