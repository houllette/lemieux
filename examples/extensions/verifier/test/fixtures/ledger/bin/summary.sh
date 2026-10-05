#!/bin/sh
# Prints one summary line: DATE TOTAL.
cents=$2
printf '%s %s\n' "$1" "$(( cents / 100 )).$(( cents % 100 ))"
