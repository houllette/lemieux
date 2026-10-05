#!/bin/sh
# Builds the production image. The pnpm version is taken from the
# packageManager field so the image matches what developers run locally.
set -eu
PNPM_VERSION=$(node -p "require('./package.json').packageManager.split('@')[1]")
TAG=${1:-storefront:latest}
docker build --build-arg "PNPM_VERSION=${PNPM_VERSION}" -t "$TAG" .
