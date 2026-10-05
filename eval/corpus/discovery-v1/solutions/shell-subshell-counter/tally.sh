#!/bin/sh
# Usage: sh tally.sh [DIR]
# Prints how many tickets in DIR/*.txt are high priority, then the total.
# Ticket files hold one ticket per line as id,priority,status; lines that
# start with # are comments.
dir=${1:-tickets}
high=0
total=0
for file in "$dir"/*.txt; do
  while IFS= read -r line; do
    case "$line" in
      '#'*) continue ;;
      *,high,*) high=$((high + 1)) ;;
    esac
    total=$((total + 1))
  done < "$file"
done
printf 'high %s\n' "$high"
printf 'total %s\n' "$total"
