#!/bin/sh
# deliver.sh <url> <event> <body-file>
set -eu
. lib/webhooks/headers.sh
. lib/webhooks/sign.sh

url=$1
event=$2
body=$(cat "$3")
sig=$(sign_body "$body")

curl -fsS -X POST "$url" \
  -H "Content-Type: application/json" \
  -H "$(event_header): $event" \
  -H "$(signature_header): $sig" \
  --data-binary "$body"
