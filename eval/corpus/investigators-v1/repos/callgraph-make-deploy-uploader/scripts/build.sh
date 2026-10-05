#!/bin/sh
set -eu
mkdir -p dist
tar -czf dist/app.tar.gz src
