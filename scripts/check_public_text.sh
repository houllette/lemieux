#!/bin/sh
# Fail when the tree uses a name this repository no longer mentions, or still
# describes the repository as it was before it became public.
#
#     scripts/check_public_text.sh
#
# Both checks read the files git tracks, in their working-tree state, so a
# local run sees uncommitted edits to tracked files. Binary files are skipped.
#
#   1. A name on the list below, in any letter case and inside any word: a
#      private project that readers cannot obtain, so naming it tells them
#      nothing. Write "an embedding host" or "a host application" instead.
#      The list is stored ROT13-encoded, so this file neither spells a name
#      out nor matches itself; `tr 'A-Za-z' 'N-ZA-Mn-za-m'` decodes an entry
#      and encodes a new one.
#
#   2. Launch-state wording in *.md and *.ex: the repository being private,
#      needing access, or having no public binary. Every one of these was true
#      once and stopped being true at the launch, which is exactly how such a
#      sentence survives review. CHANGELOG.md is a record of the past and is
#      exempt. The phrases are the five the launch plan named plus the
#      variants the launch audit found in this tree.
#
#   3. An owner placeholder: a value only the maintainer can supply, written
#      as the token below until then (the release-signing public key, the
#      Code of Conduct contact, the minimum macOS version). RELEASING.md lists
#      where each one goes. The token is assembled at run time, so this file
#      never matches itself.
#
# scripts/public_text_allowlist.txt names paths exempt from all three checks. None
# are expected; reword before reaching for it.
#
# Exit status: 0 clean, 1 findings, 2 the check could not run (not a Git
# checkout, or git grep failed, for example on a bad allowlist entry). A
# search that fails is never read as a search that found nothing.
set -eu
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd -P)
cd "$root"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "check_public_text: $root is not a Git checkout" >&2
  exit 2
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/lemieux-public-text.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

# Allowlisted paths become exclude pathspecs, collected as positional
# parameters so a path with spaces survives intact.
set --
allowlist=scripts/public_text_allowlist.txt
if [ -f "$allowlist" ]; then
  while IFS= read -r entry || [ -n "$entry" ]; do
    case $entry in
      '' | '#'*) continue ;;
    esac
    set -- "$@" ":(exclude)$entry"
  done <"$allowlist"
fi

# One encoded name per line.
printf '%s\n' \
  pubehf |
  LC_ALL=C tr 'A-Za-z' 'N-ZA-Mn-za-m' >"$scratch/names"

# Runs git grep with its output in $scratch/$1 and reports whether it found
# anything. git grep exits 0 on a match, 1 on none, and above 1 when it could
# not search; `if git grep` would read that last case as a clean tree.
search() {
  output=$1
  shift
  status=0
  git grep "$@" >"$scratch/$output" || status=$?
  case $status in
    0) return 0 ;;
    1) return 1 ;;
    *)
      echo "check_public_text: git grep failed with status $status; check $allowlist and the messages above" >&2
      exit 2
      ;;
  esac
}

found=0

if search name -I -n -i -F -f "$scratch/names" -- . "$@"; then
  lines=$(wc -l <"$scratch/name" | tr -d ' ')
  files=$(cut -d: -f1 "$scratch/name" | sort -u | wc -l | tr -d ' ')
  echo "A listed private name appears on $lines lines in $files files:"
  cut -c1-200 "$scratch/name" | sed 's/^/  /'
  echo
  found=1
fi

if search wording -I -n -i -F \
  -e 'currently private' \
  -e 'Repository access is required' \
  -e 'no public binary' \
  -e 'not advertised' \
  -e 'while the project is private' \
  -e 'while Lemieux is private' \
  -e 'until Lemieux is public' \
  -e 'advertised yet' \
  -e 'is advertised until' \
  -e 'on this private repository' \
  -- '*.md' '*.ex' ':(exclude)CHANGELOG.md' "$@"; then
  lines=$(wc -l <"$scratch/wording" | tr -d ' ')
  echo "Launch-state wording remains on $lines lines:"
  cut -c1-200 "$scratch/wording" | sed 's/^/  /'
  echo
  found=1
fi

placeholder="REPLACE_BEFORE""_LAUNCH"
if search placeholder -I -n -F -e "$placeholder" -- . "$@"; then
  lines=$(wc -l <"$scratch/placeholder" | tr -d ' ')
  echo "An owner placeholder ($placeholder) remains on $lines lines; RELEASING.md says what goes there:"
  cut -c1-200 "$scratch/placeholder" | sed 's/^/  /'
  echo
  found=1
fi

if [ "$found" -eq 1 ]; then
  cat >&2 <<'EOF'
check_public_text: failed. Describe a listed project generically ("an
embedding host", "a host application") or drop the passage, describe what is
true now rather than before the launch, and fill in every owner placeholder.
A path that must keep a match goes in scripts/public_text_allowlist.txt, with
a comment saying why.
EOF
  exit 1
fi

echo "check_public_text: no listed private names, no launch-state wording and no owner placeholders."
