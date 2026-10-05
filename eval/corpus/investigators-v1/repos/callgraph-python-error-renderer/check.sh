#!/bin/sh
# Grader for callgraph-python-error-renderer: every fixture file must be unchanged and the
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
verify README.md 4023357438
verify app/__init__.py 589208147
verify app/errors.py 1387686702
verify app/framework.py 2334068370
verify app/routes/__init__.py 4294967295
verify app/routes/health.py 1241127597
verify app/routes/orders.py 131522667
verify app/validation.py 1881676885
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\162\145\156\144\145\162\137\157\162\144\145\162\137\145\162\162\157\162'
expect 2 '\145\162\162\157\162\163\056\160\171'
echo "report ok"
