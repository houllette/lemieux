#!/bin/sh
# Usage: sh archive.sh [SRC] [DEST]
# Flattens every Markdown note under SRC/<folder>/ into DEST as
# <folder>-<file>.md so the notes can be attached to a ticket in one go.
src=${1:-notes}
dest=${2:-out}
mkdir -p $dest
for file in $(find $src -name '*.md'); do
  folder=$(basename $(dirname $file))
  cp $file $dest/$folder-$(basename $file)
done
