#!/bin/sh
# Checks that every option bin/tidy handles is documented in its usage text
# and in docs/OPTIONS.md. Prints "lint ok" on success.
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1
status=0
for opt in $(grep -o '^ *--[a-z-]*)' bin/tidy | tr -d ' )' | sort -u); do
  grep -q -- "^  $opt " bin/tidy || { echo "lint: $opt is not in the usage text"; status=1; }
  grep -q -- "^| \`$opt\` |" docs/OPTIONS.md || { echo "lint: $opt is not in docs/OPTIONS.md"; status=1; }
done
[ "$status" = 0 ] && echo "lint ok"
exit $status
