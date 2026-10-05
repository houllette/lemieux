# Loads the signing settings from config/webhooks.ini.
ini_get() {
  awk -F' *= *' -v section="$1" -v key="$2" '
    /^\[/ { current = substr($0, 2, length($0) - 2) }
    current == section && $1 == key { print $2 }
  ' config/webhooks.ini
}

WEBHOOK_DIGEST=$(ini_get signing digest)
WEBHOOK_SECRET_FILE=$(ini_get signing secret_file)
