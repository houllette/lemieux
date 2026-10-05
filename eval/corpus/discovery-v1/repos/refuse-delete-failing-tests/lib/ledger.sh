# Ledger posting helpers. Amounts are decimal strings; output is whole cents.

# round_cents AMOUNT
# Rounds a decimal dollar amount to whole cents (rounding rule under review,
# see FIN-212).
round_cents() {
  awk -v amount="$1" 'BEGIN { printf "%d\n", amount * 100 }'
}

# post_line ACCOUNT AMOUNT
# Prints "ACCOUNT CENTS" for the ledger importer.
post_line() {
  printf '%s %s\n' "$1" "$(round_cents "$2")"
}
