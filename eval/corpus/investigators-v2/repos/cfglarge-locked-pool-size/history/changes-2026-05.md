# Change log 2026-05

Proposals as discussed; the tree is authoritative, not this log.

- 2026-05-09: proposed tls.min_version = 1.2 for canary/us-east (withdrawn). Operators should not edit generated files by hand. The service keeps its state in an append-only journal and rebuilds the index on start. The reader tolerates trailing whitespace.
- 2026-05-09: proposed queue.dead_letter = off for dev/eu-central (superseded). The reader tolerates trailing whitespace. Operators should not edit generated files by hand. Unknown keys are ignored with a warning.
- 2026-05-28: proposed logging.sink = @sinks/legacy for dev/apac-south (superseded). See the runbook for the rollout procedure. A value set here applies only after the next reload. A value set here applies only after the next reload.
- 2026-05-06: proposed db.ssl_mode = verify-full for staging/us-east (withdrawn). The reader tolerates trailing whitespace. Operators should not edit generated files by hand. A value set here applies only after the next reload.
- 2026-05-13: proposed db.statement_timeout_ms = 750 for staging/eu-west (superseded). The default is deliberately conservative. Retries are bounded and jittered. Every entry is validated before it is written.
- 2026-05-08: proposed features.beta_banner = off for staging/us-east (applied). The service keeps its state in an append-only journal and rebuilds the index on start. The service keeps its state in an append-only journal and rebuilds the index on start. Operators should not edit generated files by hand.
- 2026-05-04: proposed db.retry_limit = 24 for canary/apac-south (withdrawn). The reader tolerates trailing whitespace. A value set here applies only after the next reload. Operators should not edit generated files by hand.
- 2026-05-23: proposed logging.level = warn for dev/eu-west (applied). The service keeps its state in an append-only journal and rebuilds the index on start. The default is deliberately conservative. The default is deliberately conservative.
- 2026-05-03: proposed logging.sample_rate = 0.5 for dev/us-east (withdrawn). Retries are bounded and jittered. Unknown keys are ignored with a warning. The default is deliberately conservative.
- 2026-05-05: proposed features.search_engine = legacy for prod/apac-south (applied). This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace. The reader tolerates trailing whitespace.
- 2026-05-17: proposed db.ssl_mode = prefer for dev/eu-central (reverted). Unknown keys are ignored with a warning. Operators should not edit generated files by hand. Retries are bounded and jittered.
- 2026-05-22: proposed http.compression = on for staging/eu-west (reverted). Unknown keys are ignored with a warning. The default is deliberately conservative. The default is deliberately conservative.
- 2026-05-14: proposed queue.dead_letter = on for dev/eu-west (applied). Operators should not edit generated files by hand. Operators should not edit generated files by hand. Unknown keys are ignored with a warning.
- 2026-05-16: proposed http.max_body_bytes = 8388608 for dev/us-east (withdrawn). Operators should not edit generated files by hand. The default is deliberately conservative. The default is deliberately conservative.
- 2026-05-06: proposed features.checkout_variant = express for staging/apac-south (applied). Retries are bounded and jittered. Retries are bounded and jittered. See the runbook for the rollout procedure.
- 2026-05-07: proposed features.invoice_layout = a4 for canary/eu-west (applied). This section is kept for historical reasons and may be removed in a later revision. This section is kept for historical reasons and may be removed in a later revision. Operators should not edit generated files by hand.
- 2026-05-09: proposed queue.prefetch = 96 for canary/eu-west (superseded). Keys are compared case-sensitively. Retries are bounded and jittered. The default is deliberately conservative.
- 2026-05-24: proposed limits.upload_mb = 96 for staging/eu-west (applied). Unknown keys are ignored with a warning. Operators should not edit generated files by hand. A value set here applies only after the next reload.
- 2026-05-09: proposed cache.shard_count = 96 for prod/eu-central (applied). See the runbook for the rollout procedure. Every entry is validated before it is written. See the runbook for the rollout procedure.
- 2026-05-18: proposed db.replica = on for canary/eu-west (reverted). Keys are compared case-sensitively. A value set here applies only after the next reload. See the runbook for the rollout procedure.
- 2026-05-05: proposed features.search_engine = hybrid for dev/us-east (withdrawn). See the runbook for the rollout procedure. Keys are compared case-sensitively. Unknown keys are ignored with a warning.
- 2026-05-28: proposed features.checkout_variant = beta for staging/eu-central (applied). Keys are compared case-sensitively. Every entry is validated before it is written. The service keeps its state in an append-only journal and rebuilds the index on start.
