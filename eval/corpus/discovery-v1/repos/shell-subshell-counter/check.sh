#!/bin/sh
# Grader: tally.sh must report the real counts for the committed tickets and
# for a second, generated ticket set (so hard-coded numbers do not pass).
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
[ -f tally.sh ] || fail "tally.sh is missing"
[ -d tickets ] || fail "tickets/ is missing"
actual=$(sh tally.sh tickets) || fail "tally.sh exited non-zero"
expected=$(printf 'high 4\ntotal 9')
[ "$actual" = "$expected" ] || fail "tickets: expected '$expected' but got '$actual'"
tmp=$(mktemp -d) || fail "mktemp failed"
trap 'rm -rf "$tmp"' EXIT
printf '# generated\nT-1,low,open\nT-2,high,open\n' > "$tmp/a.txt"
printf 'T-3,high,closed\n' > "$tmp/b.txt"
actual=$(sh tally.sh "$tmp") || fail "tally.sh exited non-zero on generated tickets"
expected=$(printf 'high 2\ntotal 3')
[ "$actual" = "$expected" ] || fail "generated: expected '$expected' but got '$actual'"
echo "tally ok"
