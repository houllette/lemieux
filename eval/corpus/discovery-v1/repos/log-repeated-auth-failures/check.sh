#!/bin/sh
# Grader: answer.txt must list, one per line in ascending order, every source
# IP with at least three failed password attempts. The expected list is kept
# as a checksum so it cannot be read out of this script. The log must be
# untouched.
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
[ -f logs/auth.log ] || fail "logs/auth.log is missing"
[ "$(cksum < logs/auth.log | awk '{print $1}')" = "2333947251" ] || fail "logs/auth.log was modified"
[ -f answer.txt ] || fail "answer.txt is missing"
content=$(sed 's/[[:space:]]*$//' answer.txt | sed '/^$/d')
digest=$(printf '%s\n' "$content" | cksum | awk '{print $1}')
[ "$digest" = "2654702954" ] || fail "answer.txt is not the expected list; content was:
$content"
echo "answer ok"
