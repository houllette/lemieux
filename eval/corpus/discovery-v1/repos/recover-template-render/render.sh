#!/bin/sh
# Usage: sh render.sh NAME
# Prints the welcome email for NAME.
name=$2
template=templates/welcome.tmpl
[ -f "$template" ] || { echo "render: missing template $template" >&2; exit 1; }
sed "s/{{name}}/$name/g" "$template"
