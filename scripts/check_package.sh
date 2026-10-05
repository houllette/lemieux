#!/bin/sh
# Build the Hex package and compile it as a dependency, the way an embedding
# host receives it: from the packaged source, without the optional TUI.
#
# CI's package job and the local `mix precommit.full` both run this script, so
# the package boundary is checked the same way in both places.
set -eu
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/lemieux-package.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
package="$scratch/lemieux-package"

cd "$root"
# `hex.build` must run in its own `mix` process: once anything compiles, the
# Hex archive leaves the code path and the task can no longer be found.
mix hex.build --unpack --output "$package"
test -f "$package/LICENSE"
test -f "$package/NOTICE"

cd "$root/test/package_consumer"
export LEMIEUX_PACKAGE_PATH="$package"
mix deps.get
mix compile --warnings-as-errors
mix run -e 'IO.puts(LemieuxPackageConsumer.version())'
# The phases share one transcript store. It lives in the scratch directory,
# not the consumer's tree: the transcripts record this machine's hostname and
# paths, and a store left in the checkout is one `git add -A` from a commit.
for phase in seed resume tighten; do
  mix run -e "LemieuxPackageConsumer.verify(\"$phase\", \"$scratch/contract\")"
done
