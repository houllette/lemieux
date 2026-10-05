#!/bin/sh
# Regenerates lib/status_codes.sh from src/status_codes.tsv.
# Usage: sh scripts/gen.sh
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source=src/status_codes.tsv
target=lib/status_codes.sh
count=$(grep -c . "$source")
{
  printf '%s\n' "# GENERATED FILE - do not edit by hand."
  printf '%s\n' "# Source: $source. Regenerate with: sh scripts/gen.sh"
  printf '%s\n' "# entries: $count"
  printf '%s\n' "status_name() {"
  printf '%s\n' '  case "$1" in'
  sort -n "$source" | awk -F '\t' '{ printf "    %s) printf '"'"'%%s\\n'"'"' \"%s\" ;;\n", $1, $2 }'
  printf '%s\n' '    *) printf '"'"'unknown status %s\n'"'"' "$1" >&2; return 1 ;;'
  printf '%s\n' "  esac"
  printf '%s\n' "}"
} > "$target.tmp"
mv "$target.tmp" "$target"
echo "wrote $target ($count entries)"
