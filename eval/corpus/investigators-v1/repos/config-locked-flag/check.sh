#!/bin/sh
# Grader for config-locked-flag: every fixture file must be unchanged and the
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
verify README.md 3111676793
verify flags/README.md 2226342306
verify flags/defaults.json 3332693737
verify flags/overrides/region-eu.json 1847881312
verify flags/overrides/region-us.json 3280148750
verify flags/overrides/tenant-acme.json 3970204973
verify flags/overrides/tenant-globex.json 3366521215
verify flags/tenants.json 733832164
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\143\154\141\163\163\151\143'
expect 2 '\144\145\146\141\165\154\164\163\056\152\163\157\156'
echo "report ok"
