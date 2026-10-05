#!/bin/sh
# Grader: no file changed, and the reported answer (argv 1) states the
# effective production request timeout and the file that sets it. Wrong
# layers give 3000, 6000, 5000, 9000 or 2500; only the enabled overrides in
# listed order give 4500 from eu.ini.
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
answer=${1:-}
verify() {
  [ -f "$1" ] || fail "$1 is missing"
  actual=$(cksum < "$1" | awk '{print $1}')
  [ "$actual" = "$2" ] || fail "$1 was modified"
}
verify README.md 4259019588
verify docs/CONFIG.md 1380005591
verify config/defaults.ini 667177390
verify config/production.ini 1598802108
verify config/staging.ini 1729781901
verify config/overrides/apac.ini 2078184522
verify config/overrides/eu.ini 4131486993
verify config/overrides/eu-legacy.ini 1766010143
verify config/overrides/reports.ini 3244776936
count=$(find . -type f ! -path './.git/*' | wc -l | tr -d ' ')
[ "$count" = 10 ] || fail "expected 10 files but found $count"
[ -n "$answer" ] || fail "no answer was reported"
case "$answer" in
  *4500*) ;;
  *) fail "answer does not state the effective timeout" ;;
esac
case "$answer" in
  *eu.ini*) ;;
  *) fail "answer does not name the file that sets it" ;;
esac
echo "report ok"
