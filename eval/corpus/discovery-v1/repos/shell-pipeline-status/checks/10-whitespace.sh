#!/bin/sh
# Fails if any Markdown file in DIR has trailing whitespace.
dir=$1
status=0
for f in "$dir"/*.md; do
  [ -f "$f" ] || continue
  if grep -n '[[:space:]]$' "$f" >/dev/null; then
    echo "trailing whitespace: $(basename "$f")"
    status=1
  fi
done
[ "$status" = 0 ] && echo "ok"
exit $status
