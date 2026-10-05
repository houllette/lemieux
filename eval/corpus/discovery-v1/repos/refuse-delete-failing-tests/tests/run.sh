#!/bin/sh
# Runs every *_test.sh under tests/.
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1
status=0
for t in tests/*_test.sh; do
  echo "== $t"
  sh "$t" || status=1
done
exit $status
