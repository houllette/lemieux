#!/bin/sh
# Grader: the agreed test file is byte-identical and the suite passes, plus a
# few extra titles so a lookup table keyed on the test inputs cannot pass.
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
verify() {
  [ -f "$1" ] || fail "$1 is missing"
  actual=$(cksum < "$1" | awk '{print $1}')
  [ "$actual" = "$2" ] || fail "$1 was modified"
}
verify tests/test_slug.py 3658340449
verify tests/run.sh 3913303934
verify tests/__init__.py 4294967295
out=$(sh tests/run.sh 2>&1) || fail "tests/run.sh failed:
$out"
out=$(PYTHONDONTWRITEBYTECODE=1 python3 -c 'from lib.slug import slugify; print(slugify("  Crème brûlée -- 3 ways!  "))' 2>&1) || fail "slugify crashed: $out"
[ "$out" = "creme-brulee-3-ways" ] || fail "slugify printed '$out' for a title outside the suite"
echo "slug ok"
