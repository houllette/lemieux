#!/bin/sh
# Runs the whois test suite. Exits non-zero on the first failure.
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1
. ./lib/users.sh
. ./lib/report.sh
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

out=$(sh bin/whois grace) || fail "whois grace exited non-zero"
[ "$out" = "Grace Hopper (platform)" ] || fail "whois grace printed '$out'"

out=$(sh bin/whois ada --raw) || fail "whois ada --raw exited non-zero"
[ "$out" = "$(printf 'u001\tada\tAda Lovelace\tengineering')" ] || fail "raw record was '$out'"

if sh bin/whois nobody >/dev/null 2>&1; then fail "unknown user should fail"; fi

out=$(fetch_user linus | cut -f 4) || fail "direct lookup failed"
[ "$out" = kernel ] || fail "direct lookup printed '$out'"

echo "PASS: 4 checks"
