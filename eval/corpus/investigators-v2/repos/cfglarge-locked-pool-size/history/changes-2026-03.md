# Change log 2026-03

Proposals as discussed; the tree is authoritative, not this log.

- 2026-03-18: proposed cache.backend = memory for prod/us-east (withdrawn). The default is deliberately conservative. Every entry is validated before it is written. The default is deliberately conservative.
- 2026-03-21: proposed limits.burst = 256 for canary/apac-south (applied). Keys are compared case-sensitively. The service keeps its state in an append-only journal and rebuilds the index on start. The default is deliberately conservative.
- 2026-03-04: proposed db.retry_limit = 32 for prod/eu-west (applied). A value set here applies only after the next reload. This section is kept for historical reasons and may be removed in a later revision. The default is deliberately conservative.
- 2026-03-04: proposed db.ssl_mode = prefer for dev/us-east (applied). A value set here applies only after the next reload. This section is kept for historical reasons and may be removed in a later revision. Retries are bounded and jittered.
- 2026-03-01: proposed http.keepalive_s = 90 for canary/eu-central (applied). The default is deliberately conservative. This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace.
- 2026-03-08: proposed tls.cipher_profile = modern for canary/eu-central (superseded). See the runbook for the rollout procedure. Keys are compared case-sensitively. The default is deliberately conservative.
- 2026-03-12: proposed queue.prefetch = 96 for prod/us-east (withdrawn). The default is deliberately conservative. See the runbook for the rollout procedure. The reader tolerates trailing whitespace.
- 2026-03-20: proposed limits.burst = 16 for staging/eu-west (withdrawn). A value set here applies only after the next reload. A value set here applies only after the next reload. Unknown keys are ignored with a warning.
- 2026-03-10: proposed queue.prefetch = 2048 for canary/us-east (superseded). Keys are compared case-sensitively. Every entry is validated before it is written. Retries are bounded and jittered.
- 2026-03-16: proposed cache.ttl_seconds = 60 for prod/us-east (superseded). Unknown keys are ignored with a warning. A value set here applies only after the next reload. Keys are compared case-sensitively.
- 2026-03-01: proposed cache.ttl_seconds = 120 for dev/eu-west (reverted). Keys are compared case-sensitively. See the runbook for the rollout procedure. Keys are compared case-sensitively.
- 2026-03-10: proposed queue.visibility_s = 600 for prod/us-east (withdrawn). See the runbook for the rollout procedure. This section is kept for historical reasons and may be removed in a later revision. This section is kept for historical reasons and may be removed in a later revision.
- 2026-03-27: proposed cache.max_entries = 2048 for prod/us-east (superseded). Operators should not edit generated files by hand. Operators should not edit generated files by hand. Retries are bounded and jittered.
- 2026-03-13: proposed cache.ttl_seconds = 15 for canary/eu-west (reverted). Keys are compared case-sensitively. Retries are bounded and jittered. See the runbook for the rollout procedure.
- 2026-03-25: proposed db.ssl_mode = require for prod/us-east (superseded). Keys are compared case-sensitively. The default is deliberately conservative. Every entry is validated before it is written.
- 2026-03-25: proposed db.ssl_mode = verify-full for canary/eu-central (applied). The service keeps its state in an append-only journal and rebuilds the index on start. Operators should not edit generated files by hand. Keys are compared case-sensitively.
- 2026-03-11: proposed logging.format = json for staging/apac-south (withdrawn). This section is kept for historical reasons and may be removed in a later revision. The default is deliberately conservative. Operators should not edit generated files by hand.
- 2026-03-26: proposed logging.sink = @sinks/apac-collector for prod/eu-west (withdrawn). Retries are bounded and jittered. See the runbook for the rollout procedure. The service keeps its state in an append-only journal and rebuilds the index on start.
- 2026-03-07: proposed db.retry_limit = 96 for prod/apac-south (reverted). The default is deliberately conservative. Operators should not edit generated files by hand. The default is deliberately conservative.
- 2026-03-06: proposed features.invoice_layout = compact for dev/eu-west (superseded). Unknown keys are ignored with a warning. Every entry is validated before it is written. The reader tolerates trailing whitespace.
- 2026-03-24: proposed queue.dead_letter = on for staging/eu-west (superseded). Unknown keys are ignored with a warning. This section is kept for historical reasons and may be removed in a later revision. The default is deliberately conservative.
- 2026-03-12: proposed features.search_engine = legacy for prod/eu-central (reverted). Operators should not edit generated files by hand. Keys are compared case-sensitively. The service keeps its state in an append-only journal and rebuilds the index on start.
