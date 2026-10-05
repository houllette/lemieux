# Catalog synchronisation.
sync_catalog() {
  fetch_remote "$CATALOG_URL" "$1"
  echo "catalog written to $1"
}
