#!/bin/sh
# Runs the kv test suite against a temporary store. Exits non-zero on the
# first failure.
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
STORE_FILE=$tmp/store.tsv
export STORE_FILE
. ./lib/store.sh
. ./lib/export.sh
. ./lib/import.sh
. ./lib/stats.sh
. ./tests/helpers.sh

seed_store
[ "$(store_get size)" = large ] || fail "store_get size"
[ "$(store_keys | tr '\n' ' ')" = "colour shape size " ] || fail "store_keys order"
store_put size small
[ "$(sh bin/kv-get size)" = small ] || fail "kv-get after store_put"
sh bin/kv-del shape
if store_get shape >/dev/null; then fail "store_del left the key behind"; fi
[ "$(store_count)" = 2 ] || fail "store_count"
[ "$(export_json)" = '{"colour":"blue","size":"small"}' ] || fail "export_json printed '$(export_json)'"
printf 'a=1\n# comment\nb=2\n' | sh bin/kv-load
[ "$(sh bin/kv-get b)" = 2 ] || fail "kv-load"
[ "$(sh bin/kv-dump | tail -n 1)" = "# 4 key(s)" ] || fail "kv-dump count"
[ "$(sh bin/kv-dump --json)" = '{"a":"1","b":"2","colour":"blue","size":"small"}' ] || fail "kv-dump --json"
if sh bin/kv-get missing >/dev/null 2>&1; then fail "kv-get missing should fail"; fi

echo "PASS: 11 checks"
