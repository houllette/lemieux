#!/bin/sh
# Runs the renderer checks from the repository root.
cd "$(dirname "$0")/.." || exit 1
status=0
check() {
  actual=$(sh "$1" "$2" "$3")
  if [ "$actual" = "$4" ]; then
    echo "PASS $1"
  else
    echo "FAIL $1: expected '$4', got '$actual'"
    status=1
  fi
}
check bin/receipt.sh Tea 305 "Tea 3.05"
check bin/summary.sh 2026-09-17 1005 "2026-09-17 10.05"
exit $status
