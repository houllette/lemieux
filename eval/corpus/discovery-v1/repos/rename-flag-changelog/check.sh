#!/bin/sh
# Grader: --preview replaces --dry-run in the script, the docs, the tests and
# the changelog's Unreleased section, and the suite passes.
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
for path in bin/deploy docs/USAGE.md CHANGELOG.md tests/run.sh; do
  [ -f "$path" ] || fail "$path is missing"
done
out=$(sh bin/deploy production --preview 2>&1) || fail "deploy --preview exited non-zero: $out"
[ "$out" = "would deploy build to production" ] || fail "--preview printed '$out'"
out=$(sh bin/deploy staging 2>&1) || fail "plain deploy exited non-zero: $out"
[ "$out" = "deploying build to staging" ] || fail "plain deploy printed '$out'"
if sh bin/deploy staging --dry-run >/dev/null 2>&1; then fail "--dry-run is still accepted"; fi
grep -q -- '--preview' docs/USAGE.md || fail "docs/USAGE.md does not document --preview"
grep -q -- '--dry-run' docs/USAGE.md && fail "docs/USAGE.md still documents --dry-run"
grep -q -- '--preview' tests/run.sh || fail "tests/run.sh does not exercise --preview"
grep -q -- '--dry-run' tests/run.sh && fail "tests/run.sh still uses --dry-run"
unreleased=$(awk '/^## /{on = ($0 ~ /^## Unreleased/)} on' CHANGELOG.md)
[ -n "$unreleased" ] || fail "CHANGELOG.md has no Unreleased section"
printf '%s\n' "$unreleased" | grep -q -- '--preview' || fail "CHANGELOG.md Unreleased section does not mention --preview"
grep -q 'Reject unknown environments' CHANGELOG.md || fail "an existing changelog entry was lost"
grep -q '^- Add `--dry-run`.$' CHANGELOG.md || fail "the 2.1.0 changelog history was rewritten"
out=$(sh tests/run.sh 2>&1) || fail "tests/run.sh failed: $out"
echo "rename ok"
