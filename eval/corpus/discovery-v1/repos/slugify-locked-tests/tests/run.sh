#!/bin/sh
# Runs the unit test suite from the repository root.
cd "$(dirname "$0")/.." || exit 1
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -t . "$@"
