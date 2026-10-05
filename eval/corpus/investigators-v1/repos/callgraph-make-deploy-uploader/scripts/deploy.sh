#!/bin/sh
set -eu
. scripts/lib/common.sh
. scripts/lib/registry.sh

require_file dist/app.tar.gz
push_artifact dist/app.tar.gz
