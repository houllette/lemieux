#!/bin/sh
# Fails if any Markdown file in DIR is larger than 2000 bytes.
dir=$1
status=0
for f in "$dir"/*.md; do
  [ -f "$f" ] || continue
  size=$(wc -c < "$f" | tr -d ' ')
  if [ "$size" -gt 2000 ]; then
    echo "too large ($size bytes): $(basename "$f")"
    status=1
  fi
done
[ "$status" = 0 ] && echo "ok"
exit $status
