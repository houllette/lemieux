#!/bin/sh
# Grader: archive.sh must copy every note, including those whose names contain
# spaces, into the destination with the folder prefix and unchanged contents.
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
[ -f archive.sh ] || fail "archive.sh is missing"
[ -d notes ] || fail "notes/ is missing"
tmp=$(mktemp -d) || fail "mktemp failed"
trap 'rm -rf "$tmp"' EXIT
sh archive.sh notes "$tmp/out" || fail "archive.sh exited non-zero"
[ -d "$tmp/out" ] || fail "destination directory was not created"
count=$(find "$tmp/out" -type f | wc -l | tr -d ' ')
[ "$count" = 3 ] || fail "expected 3 archived notes but found $count"
for pair in "team/meeting notes.md|team-meeting notes.md" \
            "team/roadmap.md|team-roadmap.md" \
            "personal/reading list.md|personal-reading list.md"; do
  source=${pair%%|*}
  target=${pair#*|}
  [ -f "$tmp/out/$target" ] || fail "missing archived note '$target'"
  cmp -s "notes/$source" "$tmp/out/$target" || fail "contents differ for '$target'"
done
echo "archive ok"
