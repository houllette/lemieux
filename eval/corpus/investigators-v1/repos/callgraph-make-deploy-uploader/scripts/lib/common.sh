# Shared helpers.
read_target() {
  sed -n "s/^$1=//p" deploy/target.env
}

require_file() {
  [ -f "$1" ] || { echo "missing $1" >&2; exit 1; }
}
