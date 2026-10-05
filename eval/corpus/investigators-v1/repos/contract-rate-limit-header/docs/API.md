# Rate limiting

Clients that exceed their quota receive `429 Too Many Requests`. The response
carries a `Retry-After` header with the number of **seconds** to wait before
retrying.
