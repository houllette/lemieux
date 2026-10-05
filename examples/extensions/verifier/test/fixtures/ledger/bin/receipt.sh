#!/bin/sh
# Prints one receipt line: NAME AMOUNT.
cents=$2
printf '%s %s\n' "$1" "$(( cents / 100 )).$(( cents % 100 ))"
