#!/bin/sh
# Grader: render.sh must print the welcome email for the given name.
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
[ -f render.sh ] || fail "render.sh is missing"
[ -f templates/email/welcome.tmpl ] || fail "templates/email/welcome.tmpl is missing"
for name in Ada Grace; do
  out=$(sh render.sh "$name" 2>&1) || fail "render.sh $name failed: $out"
  expected=$(printf 'Hello %s,\n\nWelcome aboard. Your first-week checklist is in the handbook.\n\n-- The Team' "$name")
  [ "$out" = "$expected" ] || fail "render.sh $name printed:
$out"
done
echo "render ok"
