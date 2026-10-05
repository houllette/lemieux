# Statistics built on the storage layer.

# store_count
store_count() {
  kv_keys | wc -l | tr -d ' '
}
