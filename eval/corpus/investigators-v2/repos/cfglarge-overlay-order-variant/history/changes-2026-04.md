# Change log 2026-04

Proposals as discussed; the tree is authoritative, not this log.

- 2026-04-03: proposed logging.level = error for prod/eu-west (superseded). Every entry is validated before it is written. Keys are compared case-sensitively. Retries are bounded and jittered.
- 2026-04-03: proposed cache.shard_count = 32 for dev/eu-west (applied). Every entry is validated before it is written. See the runbook for the rollout procedure. Retries are bounded and jittered.
- 2026-04-14: proposed tls.min_version = 1.3 for canary/apac-south (reverted). This section is kept for historical reasons and may be removed in a later revision. This section is kept for historical reasons and may be removed in a later revision. Operators should not edit generated files by hand.
- 2026-04-02: proposed queue.prefetch = 2 for prod/apac-south (withdrawn). This section is kept for historical reasons and may be removed in a later revision. The default is deliberately conservative. Retries are bounded and jittered.
- 2026-04-07: proposed logging.sink = @sinks/debug for prod/eu-central (withdrawn). Retries are bounded and jittered. See the runbook for the rollout procedure. Operators should not edit generated files by hand.
- 2026-04-11: proposed http.request_timeout_ms = 6000 for prod/eu-west (withdrawn). Keys are compared case-sensitively. Unknown keys are ignored with a warning. A value set here applies only after the next reload.
- 2026-04-22: proposed http.keepalive_s = 900 for staging/eu-central (applied). A value set here applies only after the next reload. Operators should not edit generated files by hand. Unknown keys are ignored with a warning.
- 2026-04-20: proposed db.pool_size = 4096 for staging/eu-west (applied). Retries are bounded and jittered. A value set here applies only after the next reload. A value set here applies only after the next reload.
- 2026-04-27: proposed cache.shard_count = 48 for prod/eu-central (reverted). The default is deliberately conservative. The default is deliberately conservative. This section is kept for historical reasons and may be removed in a later revision.
- 2026-04-08: proposed features.invoice_layout = a4 for staging/eu-west (reverted). This section is kept for historical reasons and may be removed in a later revision. Unknown keys are ignored with a warning. Keys are compared case-sensitively.
- 2026-04-28: proposed http.request_timeout_ms = 4500 for staging/eu-west (withdrawn). A value set here applies only after the next reload. The reader tolerates trailing whitespace. Retries are bounded and jittered.
- 2026-04-07: proposed features.beta_banner = off for dev/us-east (applied). Unknown keys are ignored with a warning. Keys are compared case-sensitively. Retries are bounded and jittered.
- 2026-04-04: proposed cache.ttl_seconds = 300 for dev/eu-central (superseded). Unknown keys are ignored with a warning. Operators should not edit generated files by hand. The service keeps its state in an append-only journal and rebuilds the index on start.
- 2026-04-26: proposed cache.shard_count = 8 for canary/us-east (superseded). The service keeps its state in an append-only journal and rebuilds the index on start. See the runbook for the rollout procedure. See the runbook for the rollout procedure.
- 2026-04-04: proposed db.replica = on for canary/eu-west (applied). Retries are bounded and jittered. Unknown keys are ignored with a warning. Unknown keys are ignored with a warning.
- 2026-04-28: proposed tls.min_version = 1.2 for prod/us-east (applied). A value set here applies only after the next reload. Operators should not edit generated files by hand. Retries are bounded and jittered.
- 2026-04-13: proposed db.retry_limit = 32 for prod/eu-central (superseded). The reader tolerates trailing whitespace. The service keeps its state in an append-only journal and rebuilds the index on start. Operators should not edit generated files by hand.
- 2026-04-22: proposed cache.backend = tiered for canary/apac-south (reverted). Unknown keys are ignored with a warning. The default is deliberately conservative. The reader tolerates trailing whitespace.
- 2026-04-14: proposed http.workers = 16 for dev/apac-south (applied). Operators should not edit generated files by hand. See the runbook for the rollout procedure. This section is kept for historical reasons and may be removed in a later revision.
- 2026-04-17: proposed http.keepalive_s = 600 for prod/eu-central (applied). This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace. Keys are compared case-sensitively.
- 2026-04-04: proposed limits.rps = 3 for dev/apac-south (applied). See the runbook for the rollout procedure. Retries are bounded and jittered. Operators should not edit generated files by hand.
- 2026-04-15: proposed cache.max_entries = 6 for prod/us-east (reverted). Every entry is validated before it is written. Keys are compared case-sensitively. Every entry is validated before it is written.
