#!/bin/sh
# Fails if any Markdown file in DIR does not start with a level-one title.
dir=$1
status=0
for f in "$dir"/*.md; do
  [ -f "$f" ] || continue
  case "$(head -n 1 "$f")" in
    '# '*) ;;
    *) echo "missing title: $(basename "$f")"; status=1 ;;
  esac
done
[ "$status" = 0 ] && echo "ok"
exit $status
