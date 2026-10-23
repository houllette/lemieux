# The stock host never pulls/builds an image during a task. Prepare this cache
# explicitly; each replay resolves the local name to its immutable image id.
FROM python@sha256:2dd78ad5cf13a0b68f5134dc49aa9950203a8cf4b7463431b9f3b398287c5059
RUN apk add --no-cache make bash git
