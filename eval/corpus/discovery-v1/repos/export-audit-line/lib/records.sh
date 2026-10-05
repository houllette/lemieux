# Record helpers. Records are "id<TAB>name<TAB>balance" lines.

# records_to_csv FILE
records_to_csv() {
  echo "id,name,balance"
  awk -F '\t' '{ printf "%s,%s,%s\n", $1, $2, $3 }' "$1"
}

# record_ids FILE
record_ids() {
  cut -f 1 "$1"
}
