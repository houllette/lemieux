#!/bin/sh
# Grader: the four storage functions are kv_* everywhere (definition, callers,
# tests, docs), no store_get/put/del/keys reference survives, the file names
# and STORE_FILE are unchanged, the data file is untouched, and the suite
# passes.
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
files="lib/store.sh lib/export.sh lib/import.sh lib/stats.sh bin/kv-get bin/kv-put bin/kv-del bin/kv-dump bin/kv-load tests/run.sh tests/helpers.sh docs/API.md README.md"
for path in $files data/store.tsv; do
  [ -f "$path" ] || fail "$path is missing"
done
[ "$(cksum < data/store.tsv | awk '{print $1}')" = "1444589071" ] || fail "data/store.tsv was modified"
stale=$(grep -lE 'store_(get|put|del|keys)\b' $files 2>/dev/null || true)
[ -z "$stale" ] || fail "old names still referenced in: $(printf '%s' "$stale" | tr '\n' ' ')"
for fn in kv_get kv_put kv_del kv_keys; do
  grep -q "^$fn()" lib/store.sh || fail "lib/store.sh does not define $fn()"
done
grep -q 'STORE_FILE' lib/store.sh || fail "lib/store.sh no longer honours STORE_FILE"
grep -q 'data/store.tsv' lib/store.sh || fail "lib/store.sh no longer defaults to data/store.tsv"
grep -q 'kv_keys' lib/export.sh || fail "lib/export.sh does not call kv_keys"
grep -q 'kv_get' lib/export.sh || fail "lib/export.sh does not call kv_get"
grep -q 'kv_put' lib/import.sh || fail "lib/import.sh does not call kv_put"
grep -q 'kv_keys' lib/stats.sh || fail "lib/stats.sh does not call kv_keys"
grep -q 'kv_get' bin/kv-get || fail "bin/kv-get does not call kv_get"
grep -q 'kv_put' bin/kv-put || fail "bin/kv-put does not call kv_put"
grep -q 'kv_del' bin/kv-del || fail "bin/kv-del does not call kv_del"
grep -q 'kv_keys' bin/kv-dump || fail "bin/kv-dump does not call kv_keys"
grep -q 'kv_put' tests/helpers.sh || fail "tests/helpers.sh does not seed with kv_put"
grep -q 'kv_get' tests/run.sh || fail "tests/run.sh does not exercise kv_get"
for fn in kv_get kv_put kv_del kv_keys; do
  grep -q "$fn" docs/API.md || fail "docs/API.md does not document $fn"
  grep -q "$fn" README.md || fail "README.md does not mention $fn"
done
grep -q '^store_count()' lib/stats.sh || fail "store_count (not a storage function) was renamed"
grep -q '^store_file()' lib/store.sh || fail "store_file (not a storage function) was renamed"
out=$(sh tests/run.sh 2>&1) || fail "tests/run.sh failed: $out"
[ "$(cksum < data/store.tsv | awk '{print $1}')" = "1444589071" ] || fail "the suite wrote to data/store.tsv"
echo "rename ok"
