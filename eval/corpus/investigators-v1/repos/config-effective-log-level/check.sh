#!/bin/sh
# Grader for config-effective-log-level: every fixture file must be unchanged and the
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
verify .env.production 847247953
verify .env.staging 1385881171
verify README.md 268786969
verify config/README.md 1835508374
verify config/base.yaml 1725793591
verify config/env/production.local.yaml 2386518993
verify config/env/production.yaml 3562384228
verify config/env/staging.yaml 2113243264
verify deploy/notify.service 3899011081
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\167\141\162\156'
expect 2 '\160\162\157\144\165\143\164\151\157\156\056\154\157\143\141\154\056\171\141\155\154'
echo "report ok"
