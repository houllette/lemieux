# Change log 2026-07

Proposals as discussed; the tree is authoritative, not this log.

- 2026-07-11: proposed queue.batch_size = 8 for canary/eu-central (applied). Operators should not edit generated files by hand. Every entry is validated before it is written. Every entry is validated before it is written.
- 2026-07-07: proposed cache.backend = disk for canary/eu-west (applied). Keys are compared case-sensitively. Keys are compared case-sensitively. The default is deliberately conservative.
- 2026-07-12: proposed limits.rps = 256 for dev/eu-central (superseded). See the runbook for the rollout procedure. Keys are compared case-sensitively. The reader tolerates trailing whitespace.
- 2026-07-01: proposed tls.key_file = ${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key for staging/apac-south (withdrawn). The reader tolerates trailing whitespace. Retries are bounded and jittered. The default is deliberately conservative.
- 2026-07-15: proposed features.invoice_layout = letter for dev/eu-west (superseded). A value set here applies only after the next reload. The default is deliberately conservative. Operators should not edit generated files by hand.
- 2026-07-25: proposed logging.sink = @sinks/primary for dev/apac-south (applied). See the runbook for the rollout procedure. Every entry is validated before it is written. Every entry is validated before it is written.
- 2026-07-09: proposed limits.concurrent_exports = 2 for staging/eu-central (withdrawn). The default is deliberately conservative. A value set here applies only after the next reload. The default is deliberately conservative.
- 2026-07-09: proposed limits.concurrent_exports = 16 for prod/us-east (applied). Retries are bounded and jittered. The default is deliberately conservative. Retries are bounded and jittered.
- 2026-07-12: proposed tls.min_version = 1.3 for staging/us-east (applied). Operators should not edit generated files by hand. Every entry is validated before it is written. Every entry is validated before it is written.
- 2026-07-12: proposed http.request_timeout_ms = 2000 for prod/eu-west (withdrawn). The reader tolerates trailing whitespace. The service keeps its state in an append-only journal and rebuilds the index on start. Unknown keys are ignored with a warning.
- 2026-07-23: proposed cache.ttl_seconds = 90 for prod/eu-central (withdrawn). The service keeps its state in an append-only journal and rebuilds the index on start. This section is kept for historical reasons and may be removed in a later revision. The default is deliberately conservative.
- 2026-07-03: proposed limits.upload_mb = 16 for canary/eu-west (withdrawn). Unknown keys are ignored with a warning. See the runbook for the rollout procedure. The service keeps its state in an append-only journal and rebuilds the index on start.
- 2026-07-21: proposed features.invoice_layout = detailed for canary/eu-west (applied). The reader tolerates trailing whitespace. The reader tolerates trailing whitespace. See the runbook for the rollout procedure.
- 2026-07-02: proposed features.checkout_variant = guided for dev/eu-central (superseded). Every entry is validated before it is written. Every entry is validated before it is written. See the runbook for the rollout procedure.
- 2026-07-26: proposed logging.sink = @sinks/archive for staging/eu-central (withdrawn). Operators should not edit generated files by hand. Every entry is validated before it is written. Unknown keys are ignored with a warning.
- 2026-07-01: proposed http.workers = 24 for canary/us-east (applied). The service keeps its state in an append-only journal and rebuilds the index on start. A value set here applies only after the next reload. A value set here applies only after the next reload.
- 2026-07-10: proposed http.keepalive_s = 120 for dev/eu-west (withdrawn). The default is deliberately conservative. The service keeps its state in an append-only journal and rebuilds the index on start. Keys are compared case-sensitively.
- 2026-07-18: proposed cache.backend = tiered for staging/eu-central (withdrawn). See the runbook for the rollout procedure. Operators should not edit generated files by hand. Every entry is validated before it is written.
- 2026-07-24: proposed http.compression = on for staging/apac-south (reverted). Every entry is validated before it is written. The default is deliberately conservative. The reader tolerates trailing whitespace.
- 2026-07-26: proposed limits.rps = 128 for canary/us-east (reverted). The reader tolerates trailing whitespace. Keys are compared case-sensitively. The reader tolerates trailing whitespace.
- 2026-07-19: proposed queue.prefetch = 256 for prod/us-east (superseded). Every entry is validated before it is written. Retries are bounded and jittered. The service keeps its state in an append-only journal and rebuilds the index on start.
- 2026-07-28: proposed tls.cert_file = ${CERT_DIR}/${SERVICE}-${REGION_SLUG}.pem for dev/eu-west (superseded). Keys are compared case-sensitively. The reader tolerates trailing whitespace. Every entry is validated before it is written.
