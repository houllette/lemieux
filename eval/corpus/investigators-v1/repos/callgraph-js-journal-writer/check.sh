#!/bin/sh
# Grader for callgraph-js-journal-writer: every fixture file must be unchanged and the
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
verify README.md 1445753571
verify src/bus.js 2773758997
verify src/handlers/cancellations.js 3899617193
verify src/handlers/index.js 3213536626
verify src/handlers/payments.js 305326388
verify src/index.js 901068818
verify src/ledger/journal.js 905566767
verify src/ledger/legacyJournal.js 1855409373
verify src/ledger/settle.js 3730808725
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\141\160\160\145\156\144\145\156\164\162\171'
expect 2 '\152\157\165\162\156\141\154\056\152\163'
echo "report ok"
