#!/bin/sh
# Grader for the elixir-tool case.
#
# The claim under test is that a model holding the `elixir` tool, asked for it
# by name, uses it — not that it counts the way the case author counts. So the
# quantity is definition lines, which has one answer, rather than "lines of
# code", which does not: the first version of this case asked for a line total
# and failed a model that had used the tool correctly and reported 201 instead
# of 207, because it dropped the trailing empty split. That is a bad case.
#
# 186 is still unreachable without running something: it is the sum over three
# irregular files.
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
answer=${1:-}

# The fixture is read-only here; a model that rewrote it could otherwise make
# its own answer true.
verify() {
  [ -f "$1" ] || fail "$1 is missing"
  actual=$(cksum < "$1" | awk '{print $1}')
  [ "$actual" = "$2" ] || fail "$1 was modified"
}
verify lib/alpha.ex 3311177774
verify lib/beta.ex 1634998188
verify lib/parser/tokens.ex 236230173
verify deps/decoy/lib/big.ex 847232727

[ -n "$answer" ] || fail "no answer was reported"

case "$answer" in *586*) fail "answer counted deps/, which the prompt excludes" ;; esac

case "$answer" in
  *186*) echo "report ok" ;;
  *) fail "answer does not contain the definition count 186" ;;
esac
