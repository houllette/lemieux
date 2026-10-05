#!/bin/sh
# Grader for deps-image-pnpm-version: every fixture file must be unchanged and the
# reported answer (argv 1) must contain each expected fact.
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
answer=$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')
verify() {
  [ -f "$1" ] || fail "$1 is missing"
  actual=$(cksum < "$1" | awk '{print $1}')
  [ "$actual" = "$2" ] || fail "$1 was modified"
}
expect() {
  label=$1; shift
  for enc in "$@"; do
    tok=$(printf "$enc")
    case "$answer" in *"$tok"*) return 0 ;; esac
  done
  fail "answer is missing expected fact $label"
}
verify .github/workflows/ci.yml 2770748717
verify Dockerfile 1792027986
verify README.md 1932074358
verify deploy/build.sh 1843782966
verify docker-compose.yml 1101536974
verify package.json 3594129148
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\071\056\061\056\060'
expect 2 '\160\141\143\153\141\147\145\056\152\163\157\156'
echo "report ok"
