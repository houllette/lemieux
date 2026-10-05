# Key reference

Every key the loader understands, its section, and the value it takes when no layer sets it. These documented fallbacks are the loader's compiled-in defaults, not what any target runs with.

## [http]

### http.request_timeout_ms

Compiled-in default: `1500`.

Every entry is validated before it is written. Retries are bounded and jittered. See the runbook for the rollout procedure. The reader tolerates trailing whitespace. Every entry is validated before it is written. A value set here applies only after the next reload.

A value set here applies only after the next reload. The reader tolerates trailing whitespace. Every entry is validated before it is written. The default is deliberately conservative. Retries are bounded and jittered.

Seen in practice: `250` (prod/apac-south), `12000` (prod/us-east), `9000` (staging/apac-south), `9000` (canary/eu-central).

The reader tolerates trailing whitespace. The service keeps its state in an append-only journal and rebuilds the index on start. Retries are bounded and jittered. The reader tolerates trailing whitespace. A value set here applies only after the next reload.

### http.max_body_bytes

Compiled-in default: `4194304`.

The default is deliberately conservative. This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace. Unknown keys are ignored with a warning. A value set here applies only after the next reload. This section is kept for historical reasons and may be removed in a later revision.

Operators should not edit generated files by hand. A value set here applies only after the next reload. A value set here applies only after the next reload. The reader tolerates trailing whitespace. The reader tolerates trailing whitespace.

Seen in practice: `2097152` (dev/eu-west), `8388608` (staging/apac-south), `1048576` (staging/us-east), `4194304` (prod/us-east).

The service keeps its state in an append-only journal and rebuilds the index on start. Retries are bounded and jittered. Operators should not edit generated files by hand. Unknown keys are ignored with a warning. Every entry is validated before it is written.

### http.keepalive_s

Compiled-in default: `15`.

Every entry is validated before it is written. Every entry is validated before it is written. See the runbook for the rollout procedure. A value set here applies only after the next reload. The default is deliberately conservative. Keys are compared case-sensitively.

Unknown keys are ignored with a warning. Unknown keys are ignored with a warning. A value set here applies only after the next reload. Unknown keys are ignored with a warning. The default is deliberately conservative.

Seen in practice: `1800` (staging/eu-central), `60` (prod/apac-south), `15` (prod/eu-central), `600` (staging/us-east).

The service keeps its state in an append-only journal and rebuilds the index on start. Retries are bounded and jittered. Retries are bounded and jittered. Retries are bounded and jittered. Keys are compared case-sensitively.

### http.workers

Compiled-in default: `20`.

A value set here applies only after the next reload. Unknown keys are ignored with a warning. Retries are bounded and jittered. Retries are bounded and jittered. A value set here applies only after the next reload. See the runbook for the rollout procedure.

Operators should not edit generated files by hand. The default is deliberately conservative. A value set here applies only after the next reload. Operators should not edit generated files by hand. See the runbook for the rollout procedure.

Seen in practice: `64` (staging/us-east), `1024` (staging/us-east), `2` (prod/us-east), `48` (dev/apac-south).

Retries are bounded and jittered. The service keeps its state in an append-only journal and rebuilds the index on start. A value set here applies only after the next reload. The default is deliberately conservative. See the runbook for the rollout procedure.

### http.compression

Compiled-in default: `off`.

Every entry is validated before it is written. Every entry is validated before it is written. Keys are compared case-sensitively. Keys are compared case-sensitively. The default is deliberately conservative. Unknown keys are ignored with a warning.

Retries are bounded and jittered. A value set here applies only after the next reload. Operators should not edit generated files by hand. The service keeps its state in an append-only journal and rebuilds the index on start. This section is kept for historical reasons and may be removed in a later revision.

Seen in practice: `off` (prod/eu-west), `off` (prod/eu-west), `off` (canary/apac-south), `on` (prod/us-east).

Every entry is validated before it is written. The service keeps its state in an append-only journal and rebuilds the index on start. The reader tolerates trailing whitespace. See the runbook for the rollout procedure. This section is kept for historical reasons and may be removed in a later revision.

## [db]

### db.pool_size

Compiled-in default: `128`.

The default is deliberately conservative. Retries are bounded and jittered. The reader tolerates trailing whitespace. Operators should not edit generated files by hand. The reader tolerates trailing whitespace. This section is kept for historical reasons and may be removed in a later revision.

The service keeps its state in an append-only journal and rebuilds the index on start. Operators should not edit generated files by hand. This section is kept for historical reasons and may be removed in a later revision. Operators should not edit generated files by hand. The reader tolerates trailing whitespace.

Seen in practice: `96` (prod/us-east), `20` (staging/eu-central), `256` (canary/eu-central), `96` (canary/eu-west).

The service keeps its state in an append-only journal and rebuilds the index on start. Keys are compared case-sensitively. Retries are bounded and jittered. A value set here applies only after the next reload. The default is deliberately conservative.

### db.statement_timeout_ms

Compiled-in default: `4500`.

See the runbook for the rollout procedure. Keys are compared case-sensitively. Retries are bounded and jittered. Keys are compared case-sensitively. See the runbook for the rollout procedure. Operators should not edit generated files by hand.

Every entry is validated before it is written. Unknown keys are ignored with a warning. The default is deliberately conservative. The default is deliberately conservative. The default is deliberately conservative.

Seen in practice: `9000` (staging/apac-south), `250` (canary/apac-south), `2000` (prod/apac-south), `1000` (canary/us-east).

Keys are compared case-sensitively. The reader tolerates trailing whitespace. Every entry is validated before it is written. Unknown keys are ignored with a warning. Every entry is validated before it is written.

### db.replica

Compiled-in default: `on`.

Keys are compared case-sensitively. Retries are bounded and jittered. Operators should not edit generated files by hand. Retries are bounded and jittered. Every entry is validated before it is written. Keys are compared case-sensitively.

Operators should not edit generated files by hand. Keys are compared case-sensitively. The default is deliberately conservative. The default is deliberately conservative. The reader tolerates trailing whitespace.

Seen in practice: `off` (prod/eu-west), `on` (canary/apac-south), `on` (prod/us-east), `on` (canary/apac-south).

Unknown keys are ignored with a warning. The default is deliberately conservative. Unknown keys are ignored with a warning. The reader tolerates trailing whitespace. Unknown keys are ignored with a warning.

### db.retry_limit

Compiled-in default: `2`.

This section is kept for historical reasons and may be removed in a later revision. Every entry is validated before it is written. This section is kept for historical reasons and may be removed in a later revision. A value set here applies only after the next reload. A value set here applies only after the next reload. The service keeps its state in an append-only journal and rebuilds the index on start.

This section is kept for historical reasons and may be removed in a later revision. A value set here applies only after the next reload. Operators should not edit generated files by hand. This section is kept for historical reasons and may be removed in a later revision. A value set here applies only after the next reload.

Seen in practice: `24` (prod/us-east), `12` (canary/us-east), `3` (staging/eu-west), `3` (canary/eu-west).

This section is kept for historical reasons and may be removed in a later revision. The service keeps its state in an append-only journal and rebuilds the index on start. A value set here applies only after the next reload. This section is kept for historical reasons and may be removed in a later revision. This section is kept for historical reasons and may be removed in a later revision.

### db.ssl_mode

Compiled-in default: `verify-full`.

Retries are bounded and jittered. Operators should not edit generated files by hand. This section is kept for historical reasons and may be removed in a later revision. Operators should not edit generated files by hand. The default is deliberately conservative. Every entry is validated before it is written.

Operators should not edit generated files by hand. This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace. The reader tolerates trailing whitespace. The service keeps its state in an append-only journal and rebuilds the index on start.

Seen in practice: `require` (staging/us-east), `require` (canary/apac-south), `verify-full` (staging/us-east), `require` (staging/us-east).

Retries are bounded and jittered. Operators should not edit generated files by hand. The default is deliberately conservative. See the runbook for the rollout procedure. The service keeps its state in an append-only journal and rebuilds the index on start.

## [cache]

### cache.ttl_seconds

Compiled-in default: `120`.

Operators should not edit generated files by hand. This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace. This section is kept for historical reasons and may be removed in a later revision. Retries are bounded and jittered. The reader tolerates trailing whitespace.

The reader tolerates trailing whitespace. Keys are compared case-sensitively. Operators should not edit generated files by hand. The default is deliberately conservative. Retries are bounded and jittered.

Seen in practice: `300` (prod/eu-west), `90` (canary/eu-west), `90` (prod/eu-central), `60` (prod/eu-central).

Every entry is validated before it is written. This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace. Operators should not edit generated files by hand. The reader tolerates trailing whitespace.

### cache.max_entries

Compiled-in default: `40`.

This section is kept for historical reasons and may be removed in a later revision. Every entry is validated before it is written. The default is deliberately conservative. The service keeps its state in an append-only journal and rebuilds the index on start. Retries are bounded and jittered. The default is deliberately conservative.

See the runbook for the rollout procedure. The service keeps its state in an append-only journal and rebuilds the index on start. Every entry is validated before it is written. See the runbook for the rollout procedure. Operators should not edit generated files by hand.

Seen in practice: `12` (prod/apac-south), `2048` (dev/apac-south), `4096` (canary/us-east), `256` (canary/eu-west).

Operators should not edit generated files by hand. Unknown keys are ignored with a warning. This section is kept for historical reasons and may be removed in a later revision. This section is kept for historical reasons and may be removed in a later revision. Unknown keys are ignored with a warning.

### cache.backend

Compiled-in default: `tiered`.

This section is kept for historical reasons and may be removed in a later revision. The default is deliberately conservative. This section is kept for historical reasons and may be removed in a later revision. Keys are compared case-sensitively. The service keeps its state in an append-only journal and rebuilds the index on start. See the runbook for the rollout procedure.

The reader tolerates trailing whitespace. See the runbook for the rollout procedure. The default is deliberately conservative. The service keeps its state in an append-only journal and rebuilds the index on start. See the runbook for the rollout procedure.

Seen in practice: `tiered` (prod/eu-central), `disk` (staging/eu-west), `memory` (staging/apac-south), `redis-like` (dev/apac-south).

A value set here applies only after the next reload. Every entry is validated before it is written. See the runbook for the rollout procedure. Operators should not edit generated files by hand. Every entry is validated before it is written.

### cache.shard_count

Compiled-in default: `20`.

This section is kept for historical reasons and may be removed in a later revision. Keys are compared case-sensitively. See the runbook for the rollout procedure. Unknown keys are ignored with a warning. Every entry is validated before it is written. The reader tolerates trailing whitespace.

See the runbook for the rollout procedure. The service keeps its state in an append-only journal and rebuilds the index on start. The reader tolerates trailing whitespace. The reader tolerates trailing whitespace. Retries are bounded and jittered.

Seen in practice: `64` (canary/apac-south), `10` (dev/apac-south), `32` (dev/us-east), `48` (dev/eu-west).

See the runbook for the rollout procedure. Operators should not edit generated files by hand. The default is deliberately conservative. Operators should not edit generated files by hand. Keys are compared case-sensitively.

## [features]

### features.checkout_variant

Compiled-in default: `compact`.

Retries are bounded and jittered. Unknown keys are ignored with a warning. The default is deliberately conservative. Every entry is validated before it is written. See the runbook for the rollout procedure. The reader tolerates trailing whitespace.

The reader tolerates trailing whitespace. Every entry is validated before it is written. Retries are bounded and jittered. The reader tolerates trailing whitespace. Keys are compared case-sensitively.

Seen in practice: `express` (canary/eu-central), `beta` (staging/eu-west), `guided` (canary/eu-central), `guided` (canary/apac-south).

Operators should not edit generated files by hand. Unknown keys are ignored with a warning. Operators should not edit generated files by hand. The default is deliberately conservative. Retries are bounded and jittered.

### features.search_engine

Compiled-in default: `lexical`.

Every entry is validated before it is written. A value set here applies only after the next reload. Unknown keys are ignored with a warning. This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace. The default is deliberately conservative.

Retries are bounded and jittered. Every entry is validated before it is written. A value set here applies only after the next reload. Unknown keys are ignored with a warning. The reader tolerates trailing whitespace.

Seen in practice: `lexical` (canary/us-east), `vector` (dev/apac-south), `hybrid` (staging/us-east), `lexical` (staging/eu-west).

Every entry is validated before it is written. This section is kept for historical reasons and may be removed in a later revision. Unknown keys are ignored with a warning. See the runbook for the rollout procedure. The reader tolerates trailing whitespace.

### features.invoice_layout

Compiled-in default: `a4`.

Every entry is validated before it is written. This section is kept for historical reasons and may be removed in a later revision. The default is deliberately conservative. This section is kept for historical reasons and may be removed in a later revision. A value set here applies only after the next reload. The service keeps its state in an append-only journal and rebuilds the index on start.

Operators should not edit generated files by hand. The service keeps its state in an append-only journal and rebuilds the index on start. Keys are compared case-sensitively. Retries are bounded and jittered. Unknown keys are ignored with a warning.

Seen in practice: `a4` (prod/eu-west), `letter` (staging/apac-south), `a4` (staging/eu-central), `a4` (canary/us-east).

Every entry is validated before it is written. The service keeps its state in an append-only journal and rebuilds the index on start. Retries are bounded and jittered. Unknown keys are ignored with a warning. The service keeps its state in an append-only journal and rebuilds the index on start.

### features.beta_banner

Compiled-in default: `on`.

Keys are compared case-sensitively. Operators should not edit generated files by hand. The reader tolerates trailing whitespace. See the runbook for the rollout procedure. Every entry is validated before it is written. This section is kept for historical reasons and may be removed in a later revision.

Every entry is validated before it is written. Every entry is validated before it is written. Operators should not edit generated files by hand. A value set here applies only after the next reload. Unknown keys are ignored with a warning.

Seen in practice: `on` (prod/us-east), `off` (canary/eu-west), `off` (dev/eu-west), `off` (staging/apac-south).

Unknown keys are ignored with a warning. This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace. Unknown keys are ignored with a warning. The default is deliberately conservative.

## [logging]

### logging.sink

Compiled-in default: `@sinks/archive`.

Every entry is validated before it is written. See the runbook for the rollout procedure. The default is deliberately conservative. Operators should not edit generated files by hand. The default is deliberately conservative. This section is kept for historical reasons and may be removed in a later revision.

A value set here applies only after the next reload. Operators should not edit generated files by hand. The reader tolerates trailing whitespace. Operators should not edit generated files by hand. This section is kept for historical reasons and may be removed in a later revision.

Seen in practice: `@sinks/legacy` (canary/eu-central), `@sinks/debug` (dev/eu-west), `@sinks/legacy` (dev/apac-south), `@sinks/debug` (dev/us-east).

A value set here applies only after the next reload. Retries are bounded and jittered. The service keeps its state in an append-only journal and rebuilds the index on start. The service keeps its state in an append-only journal and rebuilds the index on start. Keys are compared case-sensitively.

### logging.level

Compiled-in default: `info`.

Every entry is validated before it is written. This section is kept for historical reasons and may be removed in a later revision. The default is deliberately conservative. See the runbook for the rollout procedure. The default is deliberately conservative. Operators should not edit generated files by hand.

The service keeps its state in an append-only journal and rebuilds the index on start. Operators should not edit generated files by hand. Keys are compared case-sensitively. See the runbook for the rollout procedure. This section is kept for historical reasons and may be removed in a later revision.

Seen in practice: `debug` (canary/eu-west), `error` (canary/apac-south), `error` (staging/eu-west), `error` (canary/us-east).

Operators should not edit generated files by hand. A value set here applies only after the next reload. The reader tolerates trailing whitespace. Every entry is validated before it is written. Every entry is validated before it is written.

### logging.sample_rate

Compiled-in default: `0.01`.

The service keeps its state in an append-only journal and rebuilds the index on start. Operators should not edit generated files by hand. Operators should not edit generated files by hand. The service keeps its state in an append-only journal and rebuilds the index on start. Unknown keys are ignored with a warning. Keys are compared case-sensitively.

A value set here applies only after the next reload. Operators should not edit generated files by hand. Unknown keys are ignored with a warning. Keys are compared case-sensitively. Every entry is validated before it is written.

Seen in practice: `1.0` (prod/us-east), `1.0` (prod/apac-south), `0.01` (prod/eu-west), `0.05` (canary/us-east).

The default is deliberately conservative. The reader tolerates trailing whitespace. Every entry is validated before it is written. The reader tolerates trailing whitespace. The default is deliberately conservative.

### logging.format

Compiled-in default: `logfmt`.

This section is kept for historical reasons and may be removed in a later revision. Every entry is validated before it is written. Unknown keys are ignored with a warning. Operators should not edit generated files by hand. See the runbook for the rollout procedure. The default is deliberately conservative.

Keys are compared case-sensitively. A value set here applies only after the next reload. Unknown keys are ignored with a warning. This section is kept for historical reasons and may be removed in a later revision. The service keeps its state in an append-only journal and rebuilds the index on start.

Seen in practice: `text` (dev/us-east), `json` (canary/us-east), `logfmt` (canary/eu-west), `text` (dev/eu-central).

Unknown keys are ignored with a warning. The default is deliberately conservative. Operators should not edit generated files by hand. The default is deliberately conservative. This section is kept for historical reasons and may be removed in a later revision.

## [tls]

### tls.cert_file

Compiled-in default: `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.pem`.

Operators should not edit generated files by hand. Keys are compared case-sensitively. Every entry is validated before it is written. The service keeps its state in an append-only journal and rebuilds the index on start. See the runbook for the rollout procedure. Every entry is validated before it is written.

A value set here applies only after the next reload. Retries are bounded and jittered. Unknown keys are ignored with a warning. The reader tolerates trailing whitespace. Keys are compared case-sensitively.

Seen in practice: `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.pem` (prod/eu-west), `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.pem` (prod/us-east), `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.pem` (dev/apac-south), `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.pem` (prod/apac-south).

Operators should not edit generated files by hand. The service keeps its state in an append-only journal and rebuilds the index on start. The reader tolerates trailing whitespace. Every entry is validated before it is written. Every entry is validated before it is written.

### tls.key_file

Compiled-in default: `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key`.

Keys are compared case-sensitively. This section is kept for historical reasons and may be removed in a later revision. See the runbook for the rollout procedure. See the runbook for the rollout procedure. Every entry is validated before it is written. Keys are compared case-sensitively.

A value set here applies only after the next reload. Every entry is validated before it is written. Operators should not edit generated files by hand. This section is kept for historical reasons and may be removed in a later revision. This section is kept for historical reasons and may be removed in a later revision.

Seen in practice: `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key` (dev/eu-west), `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key` (dev/us-east), `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key` (canary/eu-central), `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key` (prod/us-east).

A value set here applies only after the next reload. Unknown keys are ignored with a warning. This section is kept for historical reasons and may be removed in a later revision. The service keeps its state in an append-only journal and rebuilds the index on start. Retries are bounded and jittered.

### tls.min_version

Compiled-in default: `1.2`.

The default is deliberately conservative. Keys are compared case-sensitively. Operators should not edit generated files by hand. The reader tolerates trailing whitespace. Unknown keys are ignored with a warning. The reader tolerates trailing whitespace.

Unknown keys are ignored with a warning. A value set here applies only after the next reload. Every entry is validated before it is written. See the runbook for the rollout procedure. A value set here applies only after the next reload.

Seen in practice: `1.2` (canary/eu-west), `1.3` (dev/apac-south), `1.2` (dev/apac-south), `1.3` (prod/us-east).

Every entry is validated before it is written. The default is deliberately conservative. The service keeps its state in an append-only journal and rebuilds the index on start. A value set here applies only after the next reload. Unknown keys are ignored with a warning.

### tls.cipher_profile

Compiled-in default: `modern`.

This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace. Every entry is validated before it is written. Unknown keys are ignored with a warning. The default is deliberately conservative. A value set here applies only after the next reload.

The reader tolerates trailing whitespace. Retries are bounded and jittered. Retries are bounded and jittered. See the runbook for the rollout procedure. Every entry is validated before it is written.

Seen in practice: `compat` (dev/eu-central), `modern` (prod/eu-central), `modern` (dev/eu-central), `intermediate` (prod/apac-south).

Operators should not edit generated files by hand. A value set here applies only after the next reload. Every entry is validated before it is written. The service keeps its state in an append-only journal and rebuilds the index on start. Retries are bounded and jittered.

## [queue]

### queue.prefetch

Compiled-in default: `96`.

The service keeps its state in an append-only journal and rebuilds the index on start. The default is deliberately conservative. Every entry is validated before it is written. See the runbook for the rollout procedure. The reader tolerates trailing whitespace. This section is kept for historical reasons and may be removed in a later revision.

The default is deliberately conservative. See the runbook for the rollout procedure. Unknown keys are ignored with a warning. A value set here applies only after the next reload. The default is deliberately conservative.

Seen in practice: `128` (dev/apac-south), `20` (canary/eu-west), `2` (prod/apac-south), `4` (prod/eu-central).

The default is deliberately conservative. Every entry is validated before it is written. Unknown keys are ignored with a warning. The reader tolerates trailing whitespace. Retries are bounded and jittered.

### queue.visibility_s

Compiled-in default: `30`.

The default is deliberately conservative. Every entry is validated before it is written. Retries are bounded and jittered. The service keeps its state in an append-only journal and rebuilds the index on start. The default is deliberately conservative. See the runbook for the rollout procedure.

Retries are bounded and jittered. This section is kept for historical reasons and may be removed in a later revision. This section is kept for historical reasons and may be removed in a later revision. Retries are bounded and jittered. The reader tolerates trailing whitespace.

Seen in practice: `600` (dev/eu-west), `600` (canary/eu-central), `900` (dev/eu-west), `300` (dev/us-east).

Every entry is validated before it is written. The service keeps its state in an append-only journal and rebuilds the index on start. Keys are compared case-sensitively. The reader tolerates trailing whitespace. The service keeps its state in an append-only journal and rebuilds the index on start.

### queue.dead_letter

Compiled-in default: `on`.

Every entry is validated before it is written. This section is kept for historical reasons and may be removed in a later revision. This section is kept for historical reasons and may be removed in a later revision. The default is deliberately conservative. Retries are bounded and jittered. This section is kept for historical reasons and may be removed in a later revision.

Operators should not edit generated files by hand. This section is kept for historical reasons and may be removed in a later revision. See the runbook for the rollout procedure. The service keeps its state in an append-only journal and rebuilds the index on start. The default is deliberately conservative.

Seen in practice: `on` (staging/eu-central), `off` (prod/eu-west), `off` (prod/eu-central), `on` (dev/us-east).

Operators should not edit generated files by hand. The default is deliberately conservative. Retries are bounded and jittered. Operators should not edit generated files by hand. The default is deliberately conservative.

### queue.batch_size

Compiled-in default: `64`.

Keys are compared case-sensitively. The default is deliberately conservative. This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace. This section is kept for historical reasons and may be removed in a later revision. A value set here applies only after the next reload.

Retries are bounded and jittered. This section is kept for historical reasons and may be removed in a later revision. Keys are compared case-sensitively. Retries are bounded and jittered. Keys are compared case-sensitively.

Seen in practice: `3` (staging/apac-south), `3` (staging/us-east), `48` (prod/us-east), `40` (dev/eu-west).

Unknown keys are ignored with a warning. See the runbook for the rollout procedure. The reader tolerates trailing whitespace. The reader tolerates trailing whitespace. The reader tolerates trailing whitespace.

## [limits]

### limits.rps

Compiled-in default: `128`.

The service keeps its state in an append-only journal and rebuilds the index on start. Retries are bounded and jittered. Operators should not edit generated files by hand. Every entry is validated before it is written. The reader tolerates trailing whitespace. See the runbook for the rollout procedure.

A value set here applies only after the next reload. Every entry is validated before it is written. Unknown keys are ignored with a warning. Unknown keys are ignored with a warning. This section is kept for historical reasons and may be removed in a later revision.

Seen in practice: `64` (staging/eu-central), `96` (canary/eu-central), `20` (prod/eu-central), `1024` (prod/apac-south).

This section is kept for historical reasons and may be removed in a later revision. The default is deliberately conservative. Keys are compared case-sensitively. The service keeps its state in an append-only journal and rebuilds the index on start. Operators should not edit generated files by hand.

### limits.burst

Compiled-in default: `48`.

Every entry is validated before it is written. Operators should not edit generated files by hand. The service keeps its state in an append-only journal and rebuilds the index on start. A value set here applies only after the next reload. Operators should not edit generated files by hand. The service keeps its state in an append-only journal and rebuilds the index on start.

A value set here applies only after the next reload. Unknown keys are ignored with a warning. The reader tolerates trailing whitespace. Unknown keys are ignored with a warning. Every entry is validated before it is written.

Seen in practice: `4096` (dev/apac-south), `12` (canary/eu-west), `48` (dev/eu-central), `32` (staging/eu-west).

The default is deliberately conservative. The service keeps its state in an append-only journal and rebuilds the index on start. Retries are bounded and jittered. This section is kept for historical reasons and may be removed in a later revision. The service keeps its state in an append-only journal and rebuilds the index on start.

### limits.concurrent_exports

Compiled-in default: `48`.

Operators should not edit generated files by hand. Every entry is validated before it is written. The reader tolerates trailing whitespace. Keys are compared case-sensitively. The default is deliberately conservative. Every entry is validated before it is written.

Unknown keys are ignored with a warning. Operators should not edit generated files by hand. Retries are bounded and jittered. A value set here applies only after the next reload. Retries are bounded and jittered.

Seen in practice: `24` (canary/apac-south), `96` (canary/apac-south), `3` (dev/apac-south), `256` (dev/eu-central).

Every entry is validated before it is written. Retries are bounded and jittered. See the runbook for the rollout procedure. The reader tolerates trailing whitespace. A value set here applies only after the next reload.

### limits.upload_mb

Compiled-in default: `48`.

A value set here applies only after the next reload. Every entry is validated before it is written. This section is kept for historical reasons and may be removed in a later revision. A value set here applies only after the next reload. A value set here applies only after the next reload. Unknown keys are ignored with a warning.

Keys are compared case-sensitively. The service keeps its state in an append-only journal and rebuilds the index on start. The service keeps its state in an append-only journal and rebuilds the index on start. Retries are bounded and jittered. Unknown keys are ignored with a warning.

Seen in practice: `40` (canary/us-east), `40` (canary/apac-south), `48` (staging/us-east), `128` (staging/apac-south).

Every entry is validated before it is written. The reader tolerates trailing whitespace. This section is kept for historical reasons and may be removed in a later revision. The service keeps its state in an append-only journal and rebuilds the index on start. Retries are bounded and jittered.

