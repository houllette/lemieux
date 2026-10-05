#!/bin/sh
# Grader: the requested values changed, every other setting is exactly as it
# was, and every comment line survived, in order and byte for byte.
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
[ -f config/services.ini ] || fail "config/services.ini is missing"
comments=$(grep '^[[:space:]]*[;#]' config/services.ini | cksum | awk '{print $1}')
[ "$comments" = "2533235066" ] || fail "the comment lines are not the ones the file had"
value() {
  awk -v section="$1" -v key="$2" '
    /^[[:space:]]*[;#]/ { next }
    /^\[/ { current = $0; next }
    current == "[" section "]" {
      split($0, kv, "=")
      gsub(/^[ \t]+|[ \t]+$/, "", kv[1])
      gsub(/^[ \t]+|[ \t]+$/, "", kv[2])
      if (kv[1] == key) value = kv[2]
    }
    END { print value }
  ' config/services.ini
}
expect() {
  actual=$(value "$1" "$2")
  [ "$actual" = "$3" ] || fail "[$1] $2 should be '$3' but is '$actual'"
}
expect global revision 8
expect global idle_timeout 300
expect global port 5420
expect pool.web max_connections 50
expect pool.web min_idle 2
expect pool.web warm true
expect pool.api max_connections 50
expect pool.api min_idle 4
expect pool.api warm true
expect pool.jobs max_connections 50
expect pool.jobs min_idle 1
expect pool.jobs statement_timeout 600
expect pool.jobs warm false
expect pool.audit max_connections 10
expect pool.audit min_idle 1
expect pool.audit warm false
expect pool.reports max_connections 50
expect pool.reports min_idle 0
expect pool.reports warm false
expect logging slow_query_ms 200
expect logging level info
settings=$(grep -v '^[[:space:]]*[;#]' config/services.ini | grep -v '^[[:space:]]*$' | cksum | awk '{print $1}')
[ "$settings" = "2340055730" ] || fail "the settings are not laid out as they were (order, spacing or an extra key changed)"
echo "ini ok"
