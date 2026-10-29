#!/bin/sh
# Maintainer-only entry point; Python owns durable state and process cleanup.
set -eu
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd -P)
exec python3 "$root/scripts/release.py" "$@"
