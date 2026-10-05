#!/bin/sh
# Grader for delegate-budget.
#
# The claim under test is that a delegated child comes back with a usable
# answer inside the budget the host gave it. A grader sees only the answer, so
# the case is built for an arm whose parent holds `delegate` and not `read`:
# 42500 is then unreachable except through a child that finished.
#
# It is also unreachable by guessing. The number appears in exactly one file,
# is not the configured value, and is not round. The two obvious wrong answers
# are the ones a child that stopped early would carry: 90000 if it read
# production and not the platform ceiling, 30000 if it read only the base.
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
answer=$(printf '%s' "${1:-}" | tr -d ',_ ')

verify() {
  [ -f "$1" ] || fail "$1 is missing"
  actual=$(cksum < "$1" | awk '{print $1}')
  [ "$actual" = "$2" ] || fail "$1 was modified"
}
verify README.md 1344394860
verify config/base.toml 3466865018
verify config/staging.toml 2000025245
verify config/production.toml 1015703966
verify platform/limits.toml 4279061189

[ -n "$answer" ] || fail "no answer was reported"

case "$answer" in
  *42500*) echo "report ok" ;;
  *) fail "answer does not contain the effective production timeout 42500" ;;
esac
