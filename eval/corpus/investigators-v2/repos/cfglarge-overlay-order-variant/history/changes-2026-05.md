# Change log 2026-05

Proposals as discussed; the tree is authoritative, not this log.

- 2026-05-16: proposed queue.batch_size = 256 for staging/eu-west (superseded). Operators should not edit generated files by hand. This section is kept for historical reasons and may be removed in a later revision. This section is kept for historical reasons and may be removed in a later revision.
- 2026-05-16: proposed limits.burst = 40 for staging/us-east (superseded). Retries are bounded and jittered. Unknown keys are ignored with a warning. Retries are bounded and jittered.
- 2026-05-26: proposed db.replica = off for staging/eu-central (superseded). Operators should not edit generated files by hand. A value set here applies only after the next reload. Operators should not edit generated files by hand.
- 2026-05-06: proposed cache.max_entries = 12 for staging/us-east (applied). The reader tolerates trailing whitespace. Keys are compared case-sensitively. Keys are compared case-sensitively.
- 2026-05-05: proposed queue.batch_size = 48 for canary/eu-central (withdrawn). The service keeps its state in an append-only journal and rebuilds the index on start. Keys are compared case-sensitively. Every entry is validated before it is written.
- 2026-05-03: proposed tls.min_version = 1.3 for prod/apac-south (withdrawn). The default is deliberately conservative. Retries are bounded and jittered. Every entry is validated before it is written.
- 2026-05-21: proposed http.keepalive_s = 120 for dev/eu-west (superseded). The reader tolerates trailing whitespace. The default is deliberately conservative. Retries are bounded and jittered.
- 2026-05-04: proposed limits.concurrent_exports = 40 for prod/apac-south (withdrawn). Every entry is validated before it is written. See the runbook for the rollout procedure. The reader tolerates trailing whitespace.
- 2026-05-20: proposed cache.max_entries = 16 for canary/eu-central (superseded). See the runbook for the rollout procedure. Unknown keys are ignored with a warning. The default is deliberately conservative.
- 2026-05-18: proposed features.invoice_layout = compact for staging/eu-west (applied). Operators should not edit generated files by hand. The service keeps its state in an append-only journal and rebuilds the index on start. Unknown keys are ignored with a warning.
- 2026-05-16: proposed tls.min_version = 1.3 for prod/us-east (reverted). This section is kept for historical reasons and may be removed in a later revision. The default is deliberately conservative. Every entry is validated before it is written.
- 2026-05-16: proposed cache.max_entries = 6 for dev/eu-central (applied). The reader tolerates trailing whitespace. The reader tolerates trailing whitespace. Operators should not edit generated files by hand.
- 2026-05-02: proposed tls.cipher_profile = intermediate for dev/apac-south (withdrawn). This section is kept for historical reasons and may be removed in a later revision. This section is kept for historical reasons and may be removed in a later revision. A value set here applies only after the next reload.
- 2026-05-16: proposed db.pool_size = 256 for canary/us-east (superseded). The default is deliberately conservative. A value set here applies only after the next reload. Every entry is validated before it is written.
- 2026-05-14: proposed http.workers = 6 for staging/apac-south (withdrawn). Operators should not edit generated files by hand. A value set here applies only after the next reload. Retries are bounded and jittered.
- 2026-05-17: proposed features.search_engine = vector for dev/eu-west (reverted). See the runbook for the rollout procedure. The default is deliberately conservative. See the runbook for the rollout procedure.
- 2026-05-14: proposed http.compression = on for staging/eu-central (superseded). The default is deliberately conservative. A value set here applies only after the next reload. Unknown keys are ignored with a warning.
- 2026-05-14: proposed http.keepalive_s = 30 for prod/us-east (withdrawn). The default is deliberately conservative. Unknown keys are ignored with a warning. See the runbook for the rollout procedure.
- 2026-05-08: proposed limits.concurrent_exports = 10 for dev/apac-south (reverted). Unknown keys are ignored with a warning. Every entry is validated before it is written. Unknown keys are ignored with a warning.
- 2026-05-22: proposed cache.shard_count = 64 for canary/apac-south (reverted). The reader tolerates trailing whitespace. The service keeps its state in an append-only journal and rebuilds the index on start. This section is kept for historical reasons and may be removed in a later revision.
- 2026-05-02: proposed db.pool_size = 1024 for prod/eu-west (superseded). Retries are bounded and jittered. This section is kept for historical reasons and may be removed in a later revision. See the runbook for the rollout procedure.
- 2026-05-05: proposed db.retry_limit = 8 for prod/apac-south (applied). The service keeps its state in an append-only journal and rebuilds the index on start. The reader tolerates trailing whitespace. Unknown keys are ignored with a warning.
