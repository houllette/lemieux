# Network helpers.
. "$here/lib/transport.sh"
. "$here/lib/retry.sh"

fetch_remote() {
  retry 3 download_with_curl "$1" "$2"
}

http_get() {
  curl -fsS "$1"
}
