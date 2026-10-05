# Change log 2026-04

Proposals as discussed; the tree is authoritative, not this log.

- 2026-04-07: proposed tls.key_file = ${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key for canary/eu-west (superseded). Operators should not edit generated files by hand. This section is kept for historical reasons and may be removed in a later revision. Unknown keys are ignored with a warning.
- 2026-04-05: proposed http.max_body_bytes = 8388608 for staging/eu-west (withdrawn). The reader tolerates trailing whitespace. Operators should not edit generated files by hand. Every entry is validated before it is written.
- 2026-04-08: proposed logging.format = logfmt for canary/us-east (reverted). Keys are compared case-sensitively. Unknown keys are ignored with a warning. See the runbook for the rollout procedure.
- 2026-04-16: proposed logging.format = logfmt for staging/eu-west (applied). The reader tolerates trailing whitespace. Keys are compared case-sensitively. Retries are bounded and jittered.
- 2026-04-23: proposed http.compression = off for prod/us-east (applied). Every entry is validated before it is written. Unknown keys are ignored with a warning. Keys are compared case-sensitively.
- 2026-04-12: proposed tls.key_file = ${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key for dev/apac-south (withdrawn). Keys are compared case-sensitively. Operators should not edit generated files by hand. Keys are compared case-sensitively.
- 2026-04-28: proposed http.workers = 512 for canary/eu-central (withdrawn). Keys are compared case-sensitively. Retries are bounded and jittered. Every entry is validated before it is written.
- 2026-04-16: proposed http.compression = off for canary/eu-central (applied). Keys are compared case-sensitively. The default is deliberately conservative. Keys are compared case-sensitively.
- 2026-04-16: proposed limits.concurrent_exports = 40 for prod/apac-south (withdrawn). The reader tolerates trailing whitespace. Every entry is validated before it is written. Every entry is validated before it is written.
- 2026-04-20: proposed db.ssl_mode = prefer for canary/eu-west (applied). Retries are bounded and jittered. Unknown keys are ignored with a warning. The service keeps its state in an append-only journal and rebuilds the index on start.
- 2026-04-16: proposed db.ssl_mode = require for staging/us-east (withdrawn). Unknown keys are ignored with a warning. Operators should not edit generated files by hand. The service keeps its state in an append-only journal and rebuilds the index on start.
- 2026-04-07: proposed logging.level = info for dev/apac-south (superseded). A value set here applies only after the next reload. Every entry is validated before it is written. Retries are bounded and jittered.
- 2026-04-14: proposed limits.rps = 96 for dev/us-east (superseded). See the runbook for the rollout procedure. This section is kept for historical reasons and may be removed in a later revision. Every entry is validated before it is written.
- 2026-04-03: proposed limits.concurrent_exports = 24 for dev/eu-west (superseded). Every entry is validated before it is written. The default is deliberately conservative. The service keeps its state in an append-only journal and rebuilds the index on start.
- 2026-04-17: proposed http.workers = 40 for canary/eu-west (withdrawn). The reader tolerates trailing whitespace. Operators should not edit generated files by hand. Retries are bounded and jittered.
- 2026-04-10: proposed features.search_engine = vector for staging/eu-central (applied). Retries are bounded and jittered. Every entry is validated before it is written. The service keeps its state in an append-only journal and rebuilds the index on start.
- 2026-04-03: proposed limits.upload_mb = 32 for staging/eu-west (superseded). The reader tolerates trailing whitespace. Retries are bounded and jittered. The service keeps its state in an append-only journal and rebuilds the index on start.
- 2026-04-22: proposed cache.max_entries = 6 for canary/us-east (superseded). Unknown keys are ignored with a warning. The default is deliberately conservative. A value set here applies only after the next reload.
- 2026-04-12: proposed limits.upload_mb = 512 for staging/eu-central (withdrawn). This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace. Retries are bounded and jittered.
- 2026-04-04: proposed limits.upload_mb = 20 for dev/apac-south (applied). See the runbook for the rollout procedure. Unknown keys are ignored with a warning. Every entry is validated before it is written.
- 2026-04-09: proposed logging.level = debug for prod/apac-south (withdrawn). A value set here applies only after the next reload. Every entry is validated before it is written. A value set here applies only after the next reload.
- 2026-04-26: proposed features.invoice_layout = compact for canary/apac-south (superseded). Operators should not edit generated files by hand. Operators should not edit generated files by hand. Keys are compared case-sensitively.
