#!/bin/sh
# Grader: answer.txt must name the path with the most 5xx responses and its
# count as "<path> <count>". The expected answer is kept as a checksum so it
# cannot be read out of this script. The log must be untouched.
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
[ -f logs/access.log ] || fail "logs/access.log is missing"
[ "$(cksum < logs/access.log | awk '{print $1}')" = "2285247514" ] || fail "logs/access.log was modified"
[ -f answer.txt ] || fail "answer.txt is missing"
content=$(sed 's/[[:space:]]*$//' answer.txt | sed '/^$/d')
digest=$(printf '%s\n' "$content" | cksum | awk '{print $1}')
[ "$digest" = "2008294157" ] || fail "answer.txt is not the expected answer; content was: $content"
echo "answer ok"
