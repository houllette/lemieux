# Webhook signatures

Every delivery is signed with HMAC-SHA256 over the raw request body using your
endpoint secret. The lowercase hex digest is sent in the `X-Signature` header.
Verify it before trusting the payload.
