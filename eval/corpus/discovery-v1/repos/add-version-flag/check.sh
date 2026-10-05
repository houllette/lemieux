#!/bin/sh
# Grader: --version prints the bumped VERSION, the contribution rules were
# followed (VERSION bumped, usage text and docs updated so lint passes), the
# lint script itself is untouched, and the suite still passes.
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
for path in bin/tidy VERSION docs/OPTIONS.md scripts/lint.sh tests/run.sh CONTRIBUTING.md; do
  [ -f "$path" ] || fail "$path is missing"
done
[ "$(cksum < scripts/lint.sh | awk '{print $1}')" = "4118335904" ] || fail "scripts/lint.sh was modified"
[ "$(cksum < tests/run.sh | awk '{print $1}')" = "2718853016" ] || fail "tests/run.sh was modified"
[ "$(cat VERSION)" = "1.4.3" ] || fail "VERSION is '$(cat VERSION)', expected the patch bump to 1.4.3"
out=$(sh bin/tidy --version 2>&1) || fail "tidy --version exited non-zero: $out"
[ "$out" = "tidy 1.4.3" ] || fail "tidy --version printed '$out'"
sh bin/tidy --help 2>&1 | grep -q -- '--version' || fail "usage text does not list --version"
out=$(sh scripts/lint.sh 2>&1) || fail "scripts/lint.sh failed: $out"
[ "$out" = "lint ok" ] || fail "lint printed '$out'"
out=$(sh tests/run.sh 2>&1) || fail "tests/run.sh failed: $out"
echo "version ok"
