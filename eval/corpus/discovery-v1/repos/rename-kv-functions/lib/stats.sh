# Statistics built on the storage layer.

# store_count
store_count() {
  store_keys | wc -l | tr -d ' '
}
