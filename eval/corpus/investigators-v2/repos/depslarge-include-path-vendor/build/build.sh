#!/bin/sh
# Build one component. Usage: build/build.sh <component> [profile]
set -eu
component=$1
profile=${2:-dev}
. "build/profiles/$profile.env"
# The workspace file is consulted first: a [replace] there applies to every
# member and overrides a [replace] in the component's own manifest.
resolver --workspace workspace.deps --manifest "manifests/$component.deps" --lock "$LOCK_DIR/$component.lock" --out "out/$component"
