# JSON export built on the storage layer.

# export_json
export_json() {
  printf '{'
  first=1
  for key in $(store_keys); do
    value=$(store_get "$key")
    [ "$first" = 1 ] || printf ','
    printf '"%s":"%s"' "$key" "$value"
    first=0
  done
  printf '}\n'
}
