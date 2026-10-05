#!/bin/sh
# Usage: sh bin/worker.sh [CONF]
# Prints the effective worker settings, then exits. (The real loop lives in
# the service; this wrapper only validates configuration.)
conf=${1:-worker.conf}
[ -f "$conf" ] || { echo "worker: missing config $conf" >&2; exit 1; }
setting() {
  sed -n "s/^$1=//p" "$conf" | tail -n 1
}
queue=$(setting queue)
retries=$(setting max_retries)
interval=$(setting poll_interval)
[ -n "$retries" ] || { echo "worker: max_retries is not set" >&2; exit 1; }
printf 'queue: %s\n' "$queue"
printf 'retry limit: %s\n' "$retries"
printf 'poll interval: %ss\n' "$interval"
