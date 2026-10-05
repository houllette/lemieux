#!/bin/sh
# Build one image. Usage: build/image.sh <name>
set -eu
name=$1
sh build/gen-versions.sh
args=""
while IFS='=' read -r key value; do
  case "$key" in ''|'#'*) continue ;; esac
  args="$args --build-arg $key=$value"
done < build/versions.env
image-build $args -f "images/$name/Buildfile" -t "$name:latest" .
