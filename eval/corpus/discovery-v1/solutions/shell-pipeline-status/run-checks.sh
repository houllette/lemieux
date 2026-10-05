#!/bin/sh
# Usage: run-checks.sh DIR
# Runs every checks/*.sh against DIR, prefixing output with the check name,
# and prints a summary. Exit 0 only when every check passed.
set -eu
dir=${1:?usage: run-checks.sh DIR}
[ -d "$dir" ] || { echo "run-checks: no such directory: $dir" >&2; exit 2; }
results=$(mktemp)
output=$(mktemp)
trap 'rm -f "$results" "$output"' EXIT
for check in checks/*.sh; do
  name=$(basename "$check" .sh)
  # Capture the check's status directly: the status of a pipeline is the
  # status of its last command, so piping straight into sed would hide it.
  if sh "$check" "$dir" > "$output" 2>&1; then
    echo "PASS $name" >> "$results"
  else
    echo "FAIL $name" >> "$results"
  fi
  sed "s/^/[$name] /" "$output"
done
total=$(wc -l < "$results" | tr -d ' ')
# grep -c exits 1 when nothing matches, which set -e would turn into a
# silent exit before the summary; count with awk instead.
failed=$(awk '/^FAIL/ { n++ } END { print n + 0 }' "$results")
if [ "$failed" -eq 0 ]; then
  echo "all $total checks passed"
else
  echo "$failed of $total checks failed"
  exit 1
fi
