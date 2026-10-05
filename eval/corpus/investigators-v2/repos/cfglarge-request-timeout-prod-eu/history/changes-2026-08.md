# Change log 2026-08

Proposals as discussed; the tree is authoritative, not this log.

- 2026-08-11: proposed http.keepalive_s = 90 for staging/eu-west (reverted). This section is kept for historical reasons and may be removed in a later revision. Retries are bounded and jittered. Unknown keys are ignored with a warning.
- 2026-08-13: proposed http.compression = on for canary/us-east (superseded). This section is kept for historical reasons and may be removed in a later revision. The default is deliberately conservative. Keys are compared case-sensitively.
- 2026-08-16: proposed queue.dead_letter = on for prod/apac-south (applied). Unknown keys are ignored with a warning. Retries are bounded and jittered. A value set here applies only after the next reload.
- 2026-08-21: proposed cache.max_entries = 4 for prod/us-east (applied). Unknown keys are ignored with a warning. See the runbook for the rollout procedure. Retries are bounded and jittered.
- 2026-08-25: proposed cache.backend = redis-like for dev/eu-west (superseded). See the runbook for the rollout procedure. Keys are compared case-sensitively. Retries are bounded and jittered.
- 2026-08-08: proposed cache.backend = tiered for dev/eu-central (withdrawn). The reader tolerates trailing whitespace. Operators should not edit generated files by hand. This section is kept for historical reasons and may be removed in a later revision.
- 2026-08-03: proposed features.invoice_layout = a4 for staging/eu-west (superseded). The default is deliberately conservative. Keys are compared case-sensitively. The default is deliberately conservative.
- 2026-08-27: proposed db.replica = on for prod/eu-west (superseded). See the runbook for the rollout procedure. Retries are bounded and jittered. Keys are compared case-sensitively.
- 2026-08-01: proposed http.workers = 6 for canary/us-east (applied). This section is kept for historical reasons and may be removed in a later revision. Unknown keys are ignored with a warning. Keys are compared case-sensitively.
- 2026-08-22: proposed tls.key_file = ${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key for canary/us-east (applied). See the runbook for the rollout procedure. Operators should not edit generated files by hand. Keys are compared case-sensitively.
- 2026-08-02: proposed db.retry_limit = 96 for dev/eu-central (reverted). Operators should not edit generated files by hand. Unknown keys are ignored with a warning. The service keeps its state in an append-only journal and rebuilds the index on start.
- 2026-08-25: proposed limits.upload_mb = 128 for canary/eu-west (reverted). The default is deliberately conservative. Retries are bounded and jittered. Operators should not edit generated files by hand.
- 2026-08-07: proposed queue.prefetch = 8 for staging/eu-west (applied). Every entry is validated before it is written. Unknown keys are ignored with a warning. A value set here applies only after the next reload.
- 2026-08-07: proposed tls.min_version = 1.2 for prod/apac-south (applied). Operators should not edit generated files by hand. The reader tolerates trailing whitespace. The default is deliberately conservative.
- 2026-08-18: proposed tls.key_file = ${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key for staging/eu-central (reverted). Retries are bounded and jittered. Retries are bounded and jittered. Retries are bounded and jittered.
- 2026-08-22: proposed features.beta_banner = off for staging/us-east (superseded). Retries are bounded and jittered. Unknown keys are ignored with a warning. The reader tolerates trailing whitespace.
- 2026-08-19: proposed features.beta_banner = on for prod/us-east (reverted). The reader tolerates trailing whitespace. See the runbook for the rollout procedure. This section is kept for historical reasons and may be removed in a later revision.
- 2026-08-06: proposed features.checkout_variant = express for dev/eu-central (withdrawn). Operators should not edit generated files by hand. Retries are bounded and jittered. Every entry is validated before it is written.
- 2026-08-17: proposed db.statement_timeout_ms = 250 for prod/apac-south (superseded). The default is deliberately conservative. Operators should not edit generated files by hand. Unknown keys are ignored with a warning.
- 2026-08-16: proposed http.request_timeout_ms = 12000 for staging/eu-west (applied). This section is kept for historical reasons and may be removed in a later revision. See the runbook for the rollout procedure. This section is kept for historical reasons and may be removed in a later revision.
- 2026-08-07: proposed queue.visibility_s = 300 for staging/eu-central (applied). Every entry is validated before it is written. Unknown keys are ignored with a warning. Every entry is validated before it is written.
- 2026-08-12: proposed features.checkout_variant = express for staging/apac-south (reverted). Every entry is validated before it is written. A value set here applies only after the next reload. The reader tolerates trailing whitespace.
