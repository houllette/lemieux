#!/bin/sh
# Grader: after `make all`, `make test` must actually run test/run.sh (which
# prints "app ok") instead of reporting that test is up to date.
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
[ -f Makefile ] || fail "Makefile is missing"
[ -f test/run.sh ] || fail "test/run.sh is missing"
[ -d test ] || fail "test/ directory is missing"
rm -rf build
out=$(make -s all 2>&1) || fail "make all failed: $out"
[ -f build/app.txt ] || fail "make all did not build build/app.txt"
out=$(make -s test 2>&1)
status=$?
rm -rf build
[ "$status" = 0 ] || fail "make test exited $status: $out"
case "$out" in
  *"app ok"*) echo "make ok" ;;
  *) fail "make test did not run the suite; output was: $out" ;;
esac
