#!/bin/sh
# Resolve the listening port: config/service.conf, then config/local.conf when
# it exists, then the SERVICE_PORT environment variable, then an explicit
# --port flag. A --port flag with an empty value is treated as absent.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)

read_key() {
  sed -n "s/^$2=//p" "$1" | tail -n 1
}

PORT=$(read_key "$here/config/service.conf" port)
if [ -f "$here/config/local.conf" ]; then
  PORT=$(read_key "$here/config/local.conf" port)
fi
PORT=${SERVICE_PORT:-$PORT}
for arg in "$@"; do
  case "$arg" in
    --port=?*) PORT=${arg#--port=} ;;
    --port=) ;;
  esac
done

echo "listening on port $PORT"
exec "$here/bin/server" --port "$PORT"
