# JSON export built on the storage layer.

# export_json
export_json() {
  printf '{'
  first=1
  for key in $(kv_keys); do
    value=$(kv_get "$key")
    [ "$first" = 1 ] || printf ','
    printf '"%s":"%s"' "$key" "$value"
    first=0
  done
  printf '}\n'
}
