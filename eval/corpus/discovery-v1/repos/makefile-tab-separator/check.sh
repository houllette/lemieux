#!/bin/sh
# Grader: `make` must succeed from a clean tree and produce the sorted report.
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
[ -f Makefile ] || fail "Makefile is missing"
rm -rf dist
out=$(make -s 2>&1)
status=$?
[ "$status" = 0 ] || fail "make exited $status: $out"
[ -f dist/report.txt ] || fail "dist/report.txt was not produced"
expected=$(printf 'east,40\nnorth,120\nnorth,95\nsouth,110\nsouth,80')
actual=$(cat dist/report.txt)
[ "$actual" = "$expected" ] || fail "dist/report.txt content was: $actual"
rm -rf dist
echo "make ok"
