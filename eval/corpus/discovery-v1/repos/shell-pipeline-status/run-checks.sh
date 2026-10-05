#!/bin/sh
# Usage: run-checks.sh DIR
# Runs every checks/*.sh against DIR, prefixing output with the check name,
# and prints a summary. Exit 0 only when every check passed.
set -eu
dir=${1:?usage: run-checks.sh DIR}
[ -d "$dir" ] || { echo "run-checks: no such directory: $dir" >&2; exit 2; }
results=$(mktemp)
trap 'rm -f "$results"' EXIT
for check in checks/*.sh; do
  name=$(basename "$check" .sh)
  if sh "$check" "$dir" 2>&1 | sed "s/^/[$name] /"; then
    echo "PASS $name" >> "$results"
  else
    echo "FAIL $name" >> "$results"
  fi
done
total=$(wc -l < "$results" | tr -d ' ')
failed=$(grep -c '^FAIL' "$results")
if [ "$failed" -eq 0 ]; then
  echo "all $total checks passed"
else
  echo "$failed of $total checks failed"
  exit 1
fi
