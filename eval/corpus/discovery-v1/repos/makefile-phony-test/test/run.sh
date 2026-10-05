#!/bin/sh
# Verifies the assembled build artifact.
[ -f build/app.txt ] || { echo "test: build/app.txt is missing (run make all first)"; exit 1; }
expected=$(printf 'main: boots the service\nlib: shared helpers')
[ "$(cat build/app.txt)" = "$expected" ] || { echo "test: build/app.txt has unexpected content"; exit 1; }
echo "app ok"
