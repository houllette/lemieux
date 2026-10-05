# Change log 2026-06

Proposals as discussed; the tree is authoritative, not this log.

- 2026-06-13: proposed http.request_timeout_ms = 12000 for canary/apac-south (applied). See the runbook for the rollout procedure. The reader tolerates trailing whitespace. The reader tolerates trailing whitespace.
- 2026-06-26: proposed logging.level = debug for dev/us-east (withdrawn). This section is kept for historical reasons and may be removed in a later revision. See the runbook for the rollout procedure. A value set here applies only after the next reload.
- 2026-06-22: proposed cache.shard_count = 10 for dev/eu-west (reverted). Operators should not edit generated files by hand. Retries are bounded and jittered. The reader tolerates trailing whitespace.
- 2026-06-01: proposed limits.upload_mb = 2048 for prod/eu-central (applied). The default is deliberately conservative. Unknown keys are ignored with a warning. Keys are compared case-sensitively.
- 2026-06-18: proposed http.workers = 512 for staging/eu-central (applied). Every entry is validated before it is written. A value set here applies only after the next reload. Keys are compared case-sensitively.
- 2026-06-20: proposed queue.prefetch = 1024 for canary/eu-central (reverted). See the runbook for the rollout procedure. This section is kept for historical reasons and may be removed in a later revision. The default is deliberately conservative.
- 2026-06-02: proposed tls.min_version = 1.2 for dev/eu-west (applied). Retries are bounded and jittered. Retries are bounded and jittered. Retries are bounded and jittered.
- 2026-06-21: proposed limits.burst = 4096 for staging/eu-west (superseded). Keys are compared case-sensitively. The reader tolerates trailing whitespace. Operators should not edit generated files by hand.
- 2026-06-09: proposed features.search_engine = legacy for dev/us-east (superseded). See the runbook for the rollout procedure. The service keeps its state in an append-only journal and rebuilds the index on start. Operators should not edit generated files by hand.
- 2026-06-05: proposed db.pool_size = 96 for prod/eu-central (applied). The reader tolerates trailing whitespace. Unknown keys are ignored with a warning. Retries are bounded and jittered.
- 2026-06-28: proposed tls.cipher_profile = compat for dev/eu-west (withdrawn). Retries are bounded and jittered. Unknown keys are ignored with a warning. The reader tolerates trailing whitespace.
- 2026-06-15: proposed queue.dead_letter = on for staging/apac-south (applied). The reader tolerates trailing whitespace. Keys are compared case-sensitively. A value set here applies only after the next reload.
- 2026-06-08: proposed logging.level = info for canary/eu-central (applied). The default is deliberately conservative. This section is kept for historical reasons and may be removed in a later revision. Unknown keys are ignored with a warning.
- 2026-06-26: proposed queue.dead_letter = on for dev/apac-south (superseded). Unknown keys are ignored with a warning. The service keeps its state in an append-only journal and rebuilds the index on start. Keys are compared case-sensitively.
- 2026-06-11: proposed http.request_timeout_ms = 2000 for prod/apac-south (withdrawn). This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace. Unknown keys are ignored with a warning.
- 2026-06-03: proposed db.ssl_mode = prefer for canary/us-east (applied). Operators should not edit generated files by hand. The service keeps its state in an append-only journal and rebuilds the index on start. Operators should not edit generated files by hand.
- 2026-06-18: proposed logging.sink = @sinks/apac-collector for prod/eu-west (applied). Retries are bounded and jittered. See the runbook for the rollout procedure. Unknown keys are ignored with a warning.
- 2026-06-28: proposed tls.cipher_profile = modern for canary/eu-central (withdrawn). See the runbook for the rollout procedure. Retries are bounded and jittered. Operators should not edit generated files by hand.
- 2026-06-13: proposed features.checkout_variant = beta for canary/eu-central (reverted). The service keeps its state in an append-only journal and rebuilds the index on start. Retries are bounded and jittered. Retries are bounded and jittered.
- 2026-06-17: proposed features.checkout_variant = beta for staging/eu-central (superseded). Keys are compared case-sensitively. Operators should not edit generated files by hand. Retries are bounded and jittered.
- 2026-06-13: proposed http.compression = off for dev/eu-west (withdrawn). This section is kept for historical reasons and may be removed in a later revision. Every entry is validated before it is written. Retries are bounded and jittered.
- 2026-06-04: proposed logging.sample_rate = 0.1 for prod/eu-west (reverted). The default is deliberately conservative. The default is deliberately conservative. Operators should not edit generated files by hand.
