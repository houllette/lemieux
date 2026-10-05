#!/bin/sh
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
out=$(sh bin/worker.sh) || fail "worker.sh exited non-zero"
[ "$out" = "$(printf 'queue: orders\nretry limit: 5\npoll interval: 2s')" ] || fail "unexpected output: $out"
tmp=$(mktemp) || fail "mktemp failed"
printf 'queue=refunds\nmax_retries=9\npoll_interval=1\n' > "$tmp"
out=$(sh bin/worker.sh "$tmp") || fail "worker.sh failed on custom config"
rm -f "$tmp"
[ "$out" = "$(printf 'queue: refunds\nretry limit: 9\npoll interval: 1s')" ] || fail "unexpected custom output: $out"
echo "PASS: 2 checks"
