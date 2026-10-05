# Change log 2026-07

Proposals as discussed; the tree is authoritative, not this log.

- 2026-07-26: proposed db.replica = off for canary/eu-west (withdrawn). A value set here applies only after the next reload. Every entry is validated before it is written. Unknown keys are ignored with a warning.
- 2026-07-12: proposed tls.key_file = ${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key for staging/eu-west (withdrawn). See the runbook for the rollout procedure. Retries are bounded and jittered. The default is deliberately conservative.
- 2026-07-01: proposed cache.ttl_seconds = 15 for canary/eu-central (reverted). The reader tolerates trailing whitespace. Every entry is validated before it is written. Retries are bounded and jittered.
- 2026-07-21: proposed db.statement_timeout_ms = 2000 for prod/us-east (superseded). Keys are compared case-sensitively. See the runbook for the rollout procedure. The service keeps its state in an append-only journal and rebuilds the index on start.
- 2026-07-02: proposed http.workers = 24 for dev/eu-west (superseded). The reader tolerates trailing whitespace. Every entry is validated before it is written. Unknown keys are ignored with a warning.
- 2026-07-15: proposed queue.batch_size = 4 for dev/apac-south (applied). Operators should not edit generated files by hand. This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace.
- 2026-07-15: proposed db.replica = off for canary/apac-south (reverted). Operators should not edit generated files by hand. See the runbook for the rollout procedure. Unknown keys are ignored with a warning.
- 2026-07-05: proposed tls.key_file = ${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key for dev/apac-south (applied). The reader tolerates trailing whitespace. See the runbook for the rollout procedure. Retries are bounded and jittered.
- 2026-07-23: proposed logging.sink = @sinks/debug for canary/eu-central (reverted). The default is deliberately conservative. This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace.
- 2026-07-17: proposed tls.min_version = 1.2 for prod/us-east (withdrawn). The default is deliberately conservative. Retries are bounded and jittered. The reader tolerates trailing whitespace.
- 2026-07-11: proposed limits.upload_mb = 512 for staging/us-east (superseded). The default is deliberately conservative. Retries are bounded and jittered. Keys are compared case-sensitively.
- 2026-07-28: proposed http.max_body_bytes = 16777216 for staging/us-east (withdrawn). The reader tolerates trailing whitespace. Retries are bounded and jittered. The default is deliberately conservative.
- 2026-07-27: proposed logging.format = logfmt for dev/eu-west (withdrawn). The service keeps its state in an append-only journal and rebuilds the index on start. A value set here applies only after the next reload. Retries are bounded and jittered.
- 2026-07-01: proposed limits.rps = 4 for staging/eu-central (superseded). The reader tolerates trailing whitespace. The service keeps its state in an append-only journal and rebuilds the index on start. The reader tolerates trailing whitespace.
- 2026-07-06: proposed tls.cert_file = ${CERT_DIR}/${SERVICE}-${REGION_SLUG}.pem for staging/eu-west (superseded). The default is deliberately conservative. The reader tolerates trailing whitespace. Retries are bounded and jittered.
- 2026-07-09: proposed features.search_engine = legacy for staging/us-east (withdrawn). See the runbook for the rollout procedure. This section is kept for historical reasons and may be removed in a later revision. Every entry is validated before it is written.
- 2026-07-03: proposed features.invoice_layout = letter for staging/us-east (superseded). The reader tolerates trailing whitespace. Keys are compared case-sensitively. Keys are compared case-sensitively.
- 2026-07-14: proposed limits.rps = 512 for canary/eu-west (applied). A value set here applies only after the next reload. Retries are bounded and jittered. A value set here applies only after the next reload.
- 2026-07-03: proposed limits.upload_mb = 48 for prod/apac-south (withdrawn). The default is deliberately conservative. The reader tolerates trailing whitespace. A value set here applies only after the next reload.
- 2026-07-18: proposed logging.sink = @sinks/eu-collector for prod/us-east (superseded). Keys are compared case-sensitively. Every entry is validated before it is written. Unknown keys are ignored with a warning.
- 2026-07-24: proposed cache.backend = memory for prod/apac-south (withdrawn). This section is kept for historical reasons and may be removed in a later revision. Every entry is validated before it is written. The reader tolerates trailing whitespace.
- 2026-07-08: proposed features.checkout_variant = split for prod/eu-central (applied). Keys are compared case-sensitively. Every entry is validated before it is written. Retries are bounded and jittered.
