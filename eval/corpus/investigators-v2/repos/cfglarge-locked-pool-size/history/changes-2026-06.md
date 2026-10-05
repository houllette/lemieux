# Change log 2026-06

Proposals as discussed; the tree is authoritative, not this log.

- 2026-06-08: proposed http.request_timeout_ms = 6000 for dev/apac-south (superseded). A value set here applies only after the next reload. See the runbook for the rollout procedure. The service keeps its state in an append-only journal and rebuilds the index on start.
- 2026-06-05: proposed logging.sample_rate = 1.0 for dev/eu-central (applied). This section is kept for historical reasons and may be removed in a later revision. The service keeps its state in an append-only journal and rebuilds the index on start. The reader tolerates trailing whitespace.
- 2026-06-21: proposed cache.shard_count = 16 for dev/eu-central (withdrawn). Operators should not edit generated files by hand. The default is deliberately conservative. Every entry is validated before it is written.
- 2026-06-18: proposed features.search_engine = legacy for staging/us-east (applied). See the runbook for the rollout procedure. Unknown keys are ignored with a warning. Keys are compared case-sensitively.
- 2026-06-20: proposed limits.rps = 6 for prod/eu-central (applied). See the runbook for the rollout procedure. Unknown keys are ignored with a warning. The default is deliberately conservative.
- 2026-06-18: proposed limits.rps = 6 for dev/apac-south (superseded). Operators should not edit generated files by hand. See the runbook for the rollout procedure. Every entry is validated before it is written.
- 2026-06-03: proposed tls.key_file = ${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key for dev/eu-central (withdrawn). Operators should not edit generated files by hand. The default is deliberately conservative. See the runbook for the rollout procedure.
- 2026-06-05: proposed limits.upload_mb = 64 for canary/us-east (reverted). A value set here applies only after the next reload. Unknown keys are ignored with a warning. Unknown keys are ignored with a warning.
- 2026-06-20: proposed logging.format = text for canary/eu-central (reverted). Retries are bounded and jittered. The reader tolerates trailing whitespace. The reader tolerates trailing whitespace.
- 2026-06-02: proposed cache.ttl_seconds = 45 for canary/eu-central (reverted). A value set here applies only after the next reload. The service keeps its state in an append-only journal and rebuilds the index on start. Retries are bounded and jittered.
- 2026-06-15: proposed db.pool_size = 2048 for dev/eu-west (withdrawn). See the runbook for the rollout procedure. Unknown keys are ignored with a warning. See the runbook for the rollout procedure.
- 2026-06-17: proposed limits.upload_mb = 24 for dev/us-east (reverted). Operators should not edit generated files by hand. A value set here applies only after the next reload. A value set here applies only after the next reload.
- 2026-06-05: proposed cache.backend = disk for staging/apac-south (applied). Keys are compared case-sensitively. This section is kept for historical reasons and may be removed in a later revision. A value set here applies only after the next reload.
- 2026-06-19: proposed features.invoice_layout = a4 for dev/eu-central (superseded). The service keeps its state in an append-only journal and rebuilds the index on start. Keys are compared case-sensitively. Operators should not edit generated files by hand.
- 2026-06-02: proposed queue.visibility_s = 30 for dev/us-east (superseded). The service keeps its state in an append-only journal and rebuilds the index on start. Operators should not edit generated files by hand. Retries are bounded and jittered.
- 2026-06-16: proposed logging.sample_rate = 0.25 for staging/eu-west (superseded). The service keeps its state in an append-only journal and rebuilds the index on start. A value set here applies only after the next reload. Unknown keys are ignored with a warning.
- 2026-06-05: proposed cache.shard_count = 12 for canary/apac-south (applied). The default is deliberately conservative. Unknown keys are ignored with a warning. The reader tolerates trailing whitespace.
- 2026-06-26: proposed cache.max_entries = 12 for canary/eu-west (applied). Unknown keys are ignored with a warning. The default is deliberately conservative. The default is deliberately conservative.
- 2026-06-10: proposed http.workers = 20 for staging/eu-west (withdrawn). Operators should not edit generated files by hand. See the runbook for the rollout procedure. Unknown keys are ignored with a warning.
- 2026-06-05: proposed logging.sink = @sinks/debug for staging/us-east (superseded). Keys are compared case-sensitively. The reader tolerates trailing whitespace. A value set here applies only after the next reload.
- 2026-06-24: proposed tls.key_file = ${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key for dev/eu-central (reverted). Keys are compared case-sensitively. The default is deliberately conservative. The reader tolerates trailing whitespace.
- 2026-06-01: proposed limits.upload_mb = 48 for prod/eu-west (applied). The default is deliberately conservative. Retries are bounded and jittered. Unknown keys are ignored with a warning.
