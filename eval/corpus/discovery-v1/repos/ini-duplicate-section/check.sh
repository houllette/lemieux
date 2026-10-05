#!/bin/sh
# Grader: app.ini must have exactly one [database] section whose port is 5432,
# and every other setting must be intact.
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
[ -f app.ini ] || fail "app.ini is missing"
sections=$(grep -c '^\[database\]' app.ini)
[ "$sections" = 1 ] || fail "expected one [database] section but found $sections"
value() {
  awk -v section="$1" -v key="$2" '
    /^\[/ { current = $0; next }
    current == "[" section "]" {
      split($0, kv, "=")
      gsub(/^[ \t]+|[ \t]+$/, "", kv[1])
      gsub(/^[ \t]+|[ \t]+$/, "", kv[2])
      if (kv[1] == key) value = kv[2]
    }
    END { print value }
  ' app.ini
}
expect() {
  actual=$(value "$1" "$2")
  [ "$actual" = "$3" ] || fail "[$1] $2 should be '$3' but is '$actual'"
}
expect server host 0.0.0.0
expect server port 8080
expect server workers 4
expect database host db.internal
expect database port 5432
expect database name orders
expect database pool_size 10
expect logging level info
expect logging format json
echo "ini ok"
