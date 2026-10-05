# Subcommand entry points.
. "$here/lib/sync.sh"
. "$here/lib/net.sh"

CATALOG_URL=https://catalog.example.com/v2/catalog.json
STATUS_URL=https://catalog.example.com/v2/status

cmd_sync() {
  dest=${1:-catalog.json}
  sync_catalog "$dest"
}

cmd_status() {
  http_get "$STATUS_URL"
}
