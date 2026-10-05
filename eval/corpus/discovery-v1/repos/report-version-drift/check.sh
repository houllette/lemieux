#!/bin/sh
# Grader: no file changed, and the reported answer (argv 1) names the service
# that pins a different httpc version and the version it pins.
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
answer=${1:-}
verify() {
  [ -f "$1" ] || fail "$1 is missing"
  actual=$(cksum < "$1" | awk '{print $1}')
  [ "$actual" = "$2" ] || fail "$1 was modified"
}
verify README.md 2399913652
verify services/billing/deps.lock 783119853
verify services/catalog/deps.lock 3850297125
verify services/gateway/deps.lock 1080039085
verify services/search/deps.lock 51850054
count=$(find . -type f ! -path './.git/*' | wc -l | tr -d ' ')
[ "$count" = 6 ] || fail "expected 6 files but found $count"
[ -n "$answer" ] || fail "no answer was reported"
case "$answer" in
  *billing*) ;;
  *) fail "answer does not name the drifting service" ;;
esac
case "$answer" in
  *2.3.9*) ;;
  *) fail "answer does not state the drifting version" ;;
esac
echo "report ok"
