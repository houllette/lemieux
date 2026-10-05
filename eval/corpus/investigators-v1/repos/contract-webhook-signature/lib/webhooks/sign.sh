# Computes the body signature with the configured digest.
. lib/webhooks/config.sh

webhook_secret() {
  cat "$WEBHOOK_SECRET_FILE"
}

sign_body() {
  printf '%s' "$1" | openssl dgst "-$WEBHOOK_DIGEST" -hmac "$(webhook_secret)" | awk '{print $NF}'
}
