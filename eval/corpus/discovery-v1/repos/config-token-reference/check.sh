#!/bin/sh
# Grader: the token is wired up by reference: check-config passes, the token
# resolves with .env loaded and fails to resolve without it, .env and the
# tooling are untouched, and the literal token appears in no file but .env.
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
verify() {
  [ -f "$1" ] || fail "$1 is missing"
  actual=$(cksum < "$1" | awk '{print $1}')
  [ "$actual" = "$2" ] || fail "$1 was modified"
}
verify .env 1133576463
verify .gitignore 331143695
verify bin/with-env 3235711185
verify bin/resolve-config 3406253984
verify bin/check-config 3392765495
verify docs/CONFIG.md 2219376224
token=$(sed -n 's/^PAYMENTS_API_TOKEN=//p' .env)
[ -n "$token" ] || fail "could not read the token from .env"
leaks=$(grep -rlF -- "$token" . | grep -v '^\./\.env$' || true)
[ -z "$leaks" ] || fail "the literal token was copied into: $(printf '%s' "$leaks" | tr '\n' ' ')"
out=$(sh bin/check-config 2>&1) || fail "bin/check-config failed: $out"
out=$(sh bin/with-env sh bin/resolve-config payments_token 2>&1) || fail "payments_token does not resolve: $out"
[ "$out" = "$token" ] || fail "payments_token resolved to '$out'"
if env -u PAYMENTS_API_TOKEN sh bin/resolve-config payments_token >/dev/null 2>&1; then
  fail "payments_token resolves without the environment, so it is not a reference"
fi
grep -q 'batch_size = 50' config/app.conf || fail "an existing setting was lost"
echo "token ok"
