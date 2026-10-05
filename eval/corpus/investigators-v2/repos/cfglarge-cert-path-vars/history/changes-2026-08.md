# Change log 2026-08

Proposals as discussed; the tree is authoritative, not this log.

- 2026-08-12: proposed db.replica = off for staging/us-east (superseded). Unknown keys are ignored with a warning. The default is deliberately conservative. A value set here applies only after the next reload.
- 2026-08-23: proposed cache.ttl_seconds = 600 for staging/apac-south (reverted). The service keeps its state in an append-only journal and rebuilds the index on start. Keys are compared case-sensitively. A value set here applies only after the next reload.
- 2026-08-16: proposed limits.rps = 128 for staging/us-east (withdrawn). Unknown keys are ignored with a warning. Every entry is validated before it is written. Every entry is validated before it is written.
- 2026-08-05: proposed logging.format = text for dev/eu-central (superseded). Operators should not edit generated files by hand. A value set here applies only after the next reload. Retries are bounded and jittered.
- 2026-08-22: proposed logging.level = error for canary/eu-central (reverted). This section is kept for historical reasons and may be removed in a later revision. Retries are bounded and jittered. Operators should not edit generated files by hand.
- 2026-08-14: proposed db.replica = off for canary/us-east (superseded). Keys are compared case-sensitively. This section is kept for historical reasons and may be removed in a later revision. Every entry is validated before it is written.
- 2026-08-17: proposed features.search_engine = legacy for staging/apac-south (superseded). See the runbook for the rollout procedure. Retries are bounded and jittered. Every entry is validated before it is written.
- 2026-08-09: proposed queue.batch_size = 32 for prod/eu-central (withdrawn). Retries are bounded and jittered. Retries are bounded and jittered. Every entry is validated before it is written.
- 2026-08-19: proposed limits.rps = 64 for prod/eu-west (reverted). See the runbook for the rollout procedure. A value set here applies only after the next reload. This section is kept for historical reasons and may be removed in a later revision.
- 2026-08-05: proposed queue.batch_size = 16 for canary/us-east (applied). The reader tolerates trailing whitespace. See the runbook for the rollout procedure. Every entry is validated before it is written.
- 2026-08-02: proposed tls.min_version = 1.3 for canary/us-east (superseded). Unknown keys are ignored with a warning. Retries are bounded and jittered. Keys are compared case-sensitively.
- 2026-08-05: proposed queue.visibility_s = 60 for staging/eu-central (withdrawn). Keys are compared case-sensitively. A value set here applies only after the next reload. The reader tolerates trailing whitespace.
- 2026-08-16: proposed features.invoice_layout = detailed for staging/eu-central (withdrawn). Every entry is validated before it is written. The default is deliberately conservative. Retries are bounded and jittered.
- 2026-08-08: proposed features.search_engine = legacy for prod/apac-south (withdrawn). The service keeps its state in an append-only journal and rebuilds the index on start. Unknown keys are ignored with a warning. The default is deliberately conservative.
- 2026-08-26: proposed features.checkout_variant = classic for prod/us-east (withdrawn). A value set here applies only after the next reload. Keys are compared case-sensitively. This section is kept for historical reasons and may be removed in a later revision.
- 2026-08-02: proposed db.replica = off for canary/eu-west (withdrawn). The default is deliberately conservative. The reader tolerates trailing whitespace. Every entry is validated before it is written.
- 2026-08-13: proposed db.statement_timeout_ms = 500 for canary/us-east (applied). Retries are bounded and jittered. Operators should not edit generated files by hand. See the runbook for the rollout procedure.
- 2026-08-22: proposed http.max_body_bytes = 4194304 for dev/eu-central (withdrawn). Every entry is validated before it is written. Keys are compared case-sensitively. See the runbook for the rollout procedure.
- 2026-08-17: proposed queue.dead_letter = on for canary/eu-west (withdrawn). The reader tolerates trailing whitespace. Operators should not edit generated files by hand. See the runbook for the rollout procedure.
- 2026-08-23: proposed logging.format = json for canary/eu-central (superseded). Operators should not edit generated files by hand. Retries are bounded and jittered. Retries are bounded and jittered.
- 2026-08-18: proposed features.search_engine = vector for prod/us-east (withdrawn). Every entry is validated before it is written. Keys are compared case-sensitively. This section is kept for historical reasons and may be removed in a later revision.
- 2026-08-14: proposed http.workers = 12 for canary/us-east (superseded). Operators should not edit generated files by hand. Retries are bounded and jittered. Unknown keys are ignored with a warning.
