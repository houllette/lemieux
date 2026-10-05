# Key reference

Every key the loader understands, its section, and the value it takes when no layer sets it. These documented fallbacks are the loader's compiled-in defaults, not what any target runs with.

## [http]

### http.request_timeout_ms

Compiled-in default: `4500`.

This section is kept for historical reasons and may be removed in a later revision. Every entry is validated before it is written. The default is deliberately conservative. Operators should not edit generated files by hand. Retries are bounded and jittered. This section is kept for historical reasons and may be removed in a later revision.

A value set here applies only after the next reload. A value set here applies only after the next reload. Keys are compared case-sensitively. The default is deliberately conservative. See the runbook for the rollout procedure.

Seen in practice: `3000` (canary/us-east), `4500` (staging/apac-south), `6000` (dev/eu-central), `6000` (dev/apac-south).

The default is deliberately conservative. Every entry is validated before it is written. The reader tolerates trailing whitespace. This section is kept for historical reasons and may be removed in a later revision. Every entry is validated before it is written.

### http.max_body_bytes

Compiled-in default: `2097152`.

The service keeps its state in an append-only journal and rebuilds the index on start. Operators should not edit generated files by hand. Unknown keys are ignored with a warning. A value set here applies only after the next reload. The default is deliberately conservative. See the runbook for the rollout procedure.

This section is kept for historical reasons and may be removed in a later revision. The default is deliberately conservative. Every entry is validated before it is written. Keys are compared case-sensitively. See the runbook for the rollout procedure.

Seen in practice: `1048576` (prod/eu-west), `16777216` (dev/us-east), `4194304` (canary/eu-central), `1048576` (staging/apac-south).

Keys are compared case-sensitively. Operators should not edit generated files by hand. This section is kept for historical reasons and may be removed in a later revision. Unknown keys are ignored with a warning. Every entry is validated before it is written.

### http.keepalive_s

Compiled-in default: `45`.

Unknown keys are ignored with a warning. Keys are compared case-sensitively. Every entry is validated before it is written. The service keeps its state in an append-only journal and rebuilds the index on start. This section is kept for historical reasons and may be removed in a later revision. Every entry is validated before it is written.

A value set here applies only after the next reload. Retries are bounded and jittered. Retries are bounded and jittered. Operators should not edit generated files by hand. The reader tolerates trailing whitespace.

Seen in practice: `600` (staging/eu-west), `1800` (staging/eu-west), `120` (canary/apac-south), `90` (canary/apac-south).

This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace. The service keeps its state in an append-only journal and rebuilds the index on start. See the runbook for the rollout procedure. Every entry is validated before it is written.

### http.workers

Compiled-in default: `64`.

Operators should not edit generated files by hand. Every entry is validated before it is written. The reader tolerates trailing whitespace. Every entry is validated before it is written. The service keeps its state in an append-only journal and rebuilds the index on start. A value set here applies only after the next reload.

Operators should not edit generated files by hand. The reader tolerates trailing whitespace. Unknown keys are ignored with a warning. This section is kept for historical reasons and may be removed in a later revision. The default is deliberately conservative.

Seen in practice: `512` (dev/eu-central), `20` (canary/eu-central), `8` (dev/eu-west), `64` (staging/eu-west).

This section is kept for historical reasons and may be removed in a later revision. Every entry is validated before it is written. Operators should not edit generated files by hand. Keys are compared case-sensitively. This section is kept for historical reasons and may be removed in a later revision.

### http.compression

Compiled-in default: `on`.

Unknown keys are ignored with a warning. Every entry is validated before it is written. See the runbook for the rollout procedure. The reader tolerates trailing whitespace. The service keeps its state in an append-only journal and rebuilds the index on start. A value set here applies only after the next reload.

Every entry is validated before it is written. The service keeps its state in an append-only journal and rebuilds the index on start. Operators should not edit generated files by hand. Retries are bounded and jittered. The service keeps its state in an append-only journal and rebuilds the index on start.

Seen in practice: `off` (staging/us-east), `off` (staging/us-east), `on` (staging/eu-central), `off` (dev/eu-west).

The reader tolerates trailing whitespace. Operators should not edit generated files by hand. See the runbook for the rollout procedure. A value set here applies only after the next reload. See the runbook for the rollout procedure.

## [db]

### db.pool_size

Compiled-in default: `4`.

The service keeps its state in an append-only journal and rebuilds the index on start. The reader tolerates trailing whitespace. The default is deliberately conservative. The reader tolerates trailing whitespace. Unknown keys are ignored with a warning. The service keeps its state in an append-only journal and rebuilds the index on start.

The reader tolerates trailing whitespace. Retries are bounded and jittered. A value set here applies only after the next reload. Every entry is validated before it is written. Keys are compared case-sensitively.

Seen in practice: `4096` (prod/eu-west), `4096` (staging/eu-west), `6` (dev/us-east), `12` (canary/eu-west).

See the runbook for the rollout procedure. The default is deliberately conservative. Retries are bounded and jittered. This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace.

### db.statement_timeout_ms

Compiled-in default: `9000`.

The reader tolerates trailing whitespace. A value set here applies only after the next reload. Every entry is validated before it is written. Keys are compared case-sensitively. The default is deliberately conservative. See the runbook for the rollout procedure.

Keys are compared case-sensitively. A value set here applies only after the next reload. The reader tolerates trailing whitespace. Keys are compared case-sensitively. See the runbook for the rollout procedure.

Seen in practice: `3000` (canary/eu-west), `500` (canary/eu-west), `250` (dev/apac-south), `2000` (prod/eu-central).

The service keeps its state in an append-only journal and rebuilds the index on start. This section is kept for historical reasons and may be removed in a later revision. See the runbook for the rollout procedure. Operators should not edit generated files by hand. Operators should not edit generated files by hand.

### db.replica

Compiled-in default: `off`.

The reader tolerates trailing whitespace. This section is kept for historical reasons and may be removed in a later revision. The default is deliberately conservative. Keys are compared case-sensitively. Keys are compared case-sensitively. Every entry is validated before it is written.

The service keeps its state in an append-only journal and rebuilds the index on start. The default is deliberately conservative. See the runbook for the rollout procedure. Retries are bounded and jittered. Retries are bounded and jittered.

Seen in practice: `off` (staging/eu-west), `on` (staging/eu-central), `off` (staging/us-east), `on` (canary/eu-central).

The service keeps its state in an append-only journal and rebuilds the index on start. The default is deliberately conservative. Retries are bounded and jittered. Every entry is validated before it is written. A value set here applies only after the next reload.

### db.retry_limit

Compiled-in default: `256`.

Every entry is validated before it is written. The reader tolerates trailing whitespace. Keys are compared case-sensitively. The default is deliberately conservative. The reader tolerates trailing whitespace. The reader tolerates trailing whitespace.

Keys are compared case-sensitively. Operators should not edit generated files by hand. The reader tolerates trailing whitespace. The reader tolerates trailing whitespace. Retries are bounded and jittered.

Seen in practice: `8` (canary/eu-central), `3` (prod/eu-west), `10` (staging/apac-south), `1024` (dev/eu-west).

The default is deliberately conservative. This section is kept for historical reasons and may be removed in a later revision. Every entry is validated before it is written. This section is kept for historical reasons and may be removed in a later revision. Retries are bounded and jittered.

### db.ssl_mode

Compiled-in default: `prefer`.

The reader tolerates trailing whitespace. The reader tolerates trailing whitespace. The reader tolerates trailing whitespace. The reader tolerates trailing whitespace. A value set here applies only after the next reload. Unknown keys are ignored with a warning.

Every entry is validated before it is written. The default is deliberately conservative. Retries are bounded and jittered. Operators should not edit generated files by hand. The service keeps its state in an append-only journal and rebuilds the index on start.

Seen in practice: `verify-full` (staging/eu-west), `prefer` (staging/eu-west), `prefer` (staging/us-east), `require` (dev/eu-west).

This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace. The service keeps its state in an append-only journal and rebuilds the index on start. The reader tolerates trailing whitespace. The service keeps its state in an append-only journal and rebuilds the index on start.

## [cache]

### cache.ttl_seconds

Compiled-in default: `600`.

The default is deliberately conservative. Retries are bounded and jittered. Operators should not edit generated files by hand. Every entry is validated before it is written. Unknown keys are ignored with a warning. Retries are bounded and jittered.

The service keeps its state in an append-only journal and rebuilds the index on start. Operators should not edit generated files by hand. Retries are bounded and jittered. The default is deliberately conservative. See the runbook for the rollout procedure.

Seen in practice: `900` (staging/eu-central), `90` (staging/apac-south), `45` (prod/eu-west), `1800` (dev/us-east).

The reader tolerates trailing whitespace. Every entry is validated before it is written. Unknown keys are ignored with a warning. Unknown keys are ignored with a warning. The default is deliberately conservative.

### cache.max_entries

Compiled-in default: `10`.

The default is deliberately conservative. A value set here applies only after the next reload. The service keeps its state in an append-only journal and rebuilds the index on start. Keys are compared case-sensitively. The reader tolerates trailing whitespace. Every entry is validated before it is written.

This section is kept for historical reasons and may be removed in a later revision. Unknown keys are ignored with a warning. Operators should not edit generated files by hand. The reader tolerates trailing whitespace. The reader tolerates trailing whitespace.

Seen in practice: `512` (staging/apac-south), `24` (staging/eu-west), `2` (dev/eu-west), `16` (canary/eu-west).

Unknown keys are ignored with a warning. The reader tolerates trailing whitespace. The reader tolerates trailing whitespace. Operators should not edit generated files by hand. Every entry is validated before it is written.

### cache.backend

Compiled-in default: `tiered`.

The default is deliberately conservative. The reader tolerates trailing whitespace. A value set here applies only after the next reload. The reader tolerates trailing whitespace. Retries are bounded and jittered. Unknown keys are ignored with a warning.

See the runbook for the rollout procedure. The default is deliberately conservative. Keys are compared case-sensitively. Retries are bounded and jittered. See the runbook for the rollout procedure.

Seen in practice: `memory` (staging/eu-central), `memory` (canary/eu-west), `tiered` (prod/eu-central), `memory` (prod/apac-south).

This section is kept for historical reasons and may be removed in a later revision. The service keeps its state in an append-only journal and rebuilds the index on start. The default is deliberately conservative. This section is kept for historical reasons and may be removed in a later revision. The service keeps its state in an append-only journal and rebuilds the index on start.

### cache.shard_count

Compiled-in default: `2048`.

Keys are compared case-sensitively. A value set here applies only after the next reload. See the runbook for the rollout procedure. The service keeps its state in an append-only journal and rebuilds the index on start. This section is kept for historical reasons and may be removed in a later revision. Operators should not edit generated files by hand.

This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace. Retries are bounded and jittered. See the runbook for the rollout procedure. Keys are compared case-sensitively.

Seen in practice: `48` (staging/eu-west), `256` (prod/eu-central), `4` (canary/eu-west), `16` (dev/us-east).

The service keeps its state in an append-only journal and rebuilds the index on start. The default is deliberately conservative. This section is kept for historical reasons and may be removed in a later revision. A value set here applies only after the next reload. A value set here applies only after the next reload.

## [features]

### features.checkout_variant

Compiled-in default: `compact`.

The reader tolerates trailing whitespace. Operators should not edit generated files by hand. Operators should not edit generated files by hand. Operators should not edit generated files by hand. The default is deliberately conservative. The reader tolerates trailing whitespace.

Every entry is validated before it is written. The service keeps its state in an append-only journal and rebuilds the index on start. The service keeps its state in an append-only journal and rebuilds the index on start. The default is deliberately conservative. This section is kept for historical reasons and may be removed in a later revision.

Seen in practice: `compact` (canary/apac-south), `split` (staging/us-east), `express` (canary/eu-west), `guided` (dev/apac-south).

See the runbook for the rollout procedure. Retries are bounded and jittered. The service keeps its state in an append-only journal and rebuilds the index on start. Unknown keys are ignored with a warning. Unknown keys are ignored with a warning.

### features.search_engine

Compiled-in default: `lexical`.

This section is kept for historical reasons and may be removed in a later revision. A value set here applies only after the next reload. Keys are compared case-sensitively. Every entry is validated before it is written. Retries are bounded and jittered. Keys are compared case-sensitively.

This section is kept for historical reasons and may be removed in a later revision. The default is deliberately conservative. Keys are compared case-sensitively. Operators should not edit generated files by hand. Operators should not edit generated files by hand.

Seen in practice: `vector` (prod/eu-west), `hybrid` (dev/eu-west), `lexical` (canary/us-east), `vector` (canary/apac-south).

Keys are compared case-sensitively. The default is deliberately conservative. Operators should not edit generated files by hand. The service keeps its state in an append-only journal and rebuilds the index on start. A value set here applies only after the next reload.

### features.invoice_layout

Compiled-in default: `compact`.

Every entry is validated before it is written. The default is deliberately conservative. The reader tolerates trailing whitespace. This section is kept for historical reasons and may be removed in a later revision. Keys are compared case-sensitively. The reader tolerates trailing whitespace.

Retries are bounded and jittered. Keys are compared case-sensitively. Every entry is validated before it is written. Keys are compared case-sensitively. Every entry is validated before it is written.

Seen in practice: `detailed` (prod/eu-central), `a4` (dev/eu-west), `letter` (canary/apac-south), `detailed` (prod/apac-south).

Keys are compared case-sensitively. Operators should not edit generated files by hand. Operators should not edit generated files by hand. Every entry is validated before it is written. The reader tolerates trailing whitespace.

### features.beta_banner

Compiled-in default: `off`.

The reader tolerates trailing whitespace. Unknown keys are ignored with a warning. A value set here applies only after the next reload. The default is deliberately conservative. Unknown keys are ignored with a warning. Unknown keys are ignored with a warning.

Retries are bounded and jittered. This section is kept for historical reasons and may be removed in a later revision. Keys are compared case-sensitively. Every entry is validated before it is written. The reader tolerates trailing whitespace.

Seen in practice: `on` (prod/apac-south), `on` (canary/us-east), `off` (dev/eu-central), `off` (prod/us-east).

Unknown keys are ignored with a warning. Keys are compared case-sensitively. Every entry is validated before it is written. The service keeps its state in an append-only journal and rebuilds the index on start. A value set here applies only after the next reload.

## [logging]

### logging.sink

Compiled-in default: `@sinks/apac-collector`.

The service keeps its state in an append-only journal and rebuilds the index on start. The service keeps its state in an append-only journal and rebuilds the index on start. Operators should not edit generated files by hand. Every entry is validated before it is written. Retries are bounded and jittered. The service keeps its state in an append-only journal and rebuilds the index on start.

Operators should not edit generated files by hand. Unknown keys are ignored with a warning. See the runbook for the rollout procedure. See the runbook for the rollout procedure. Retries are bounded and jittered.

Seen in practice: `@sinks/primary` (prod/apac-south), `@sinks/debug` (staging/apac-south), `@sinks/primary` (staging/eu-west), `@sinks/debug` (dev/eu-central).

The reader tolerates trailing whitespace. Every entry is validated before it is written. The service keeps its state in an append-only journal and rebuilds the index on start. This section is kept for historical reasons and may be removed in a later revision. See the runbook for the rollout procedure.

### logging.level

Compiled-in default: `debug`.

See the runbook for the rollout procedure. The default is deliberately conservative. A value set here applies only after the next reload. Retries are bounded and jittered. Operators should not edit generated files by hand. Operators should not edit generated files by hand.

This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace. See the runbook for the rollout procedure. Operators should not edit generated files by hand. The default is deliberately conservative.

Seen in practice: `debug` (prod/eu-central), `error` (dev/us-east), `error` (prod/eu-central), `error` (dev/eu-west).

See the runbook for the rollout procedure. Retries are bounded and jittered. See the runbook for the rollout procedure. The reader tolerates trailing whitespace. This section is kept for historical reasons and may be removed in a later revision.

### logging.sample_rate

Compiled-in default: `0.01`.

Every entry is validated before it is written. The default is deliberately conservative. The reader tolerates trailing whitespace. The service keeps its state in an append-only journal and rebuilds the index on start. The reader tolerates trailing whitespace. Unknown keys are ignored with a warning.

Every entry is validated before it is written. Every entry is validated before it is written. A value set here applies only after the next reload. The default is deliberately conservative. The reader tolerates trailing whitespace.

Seen in practice: `0.01` (dev/eu-central), `0.1` (canary/us-east), `0.1` (prod/eu-central), `0.25` (dev/apac-south).

The reader tolerates trailing whitespace. The reader tolerates trailing whitespace. Operators should not edit generated files by hand. The reader tolerates trailing whitespace. The reader tolerates trailing whitespace.

### logging.format

Compiled-in default: `json`.

See the runbook for the rollout procedure. Keys are compared case-sensitively. Unknown keys are ignored with a warning. The service keeps its state in an append-only journal and rebuilds the index on start. See the runbook for the rollout procedure. Retries are bounded and jittered.

The reader tolerates trailing whitespace. See the runbook for the rollout procedure. The default is deliberately conservative. Every entry is validated before it is written. Unknown keys are ignored with a warning.

Seen in practice: `text` (prod/us-east), `logfmt` (canary/eu-central), `text` (canary/eu-central), `logfmt` (dev/eu-west).

Keys are compared case-sensitively. The default is deliberately conservative. This section is kept for historical reasons and may be removed in a later revision. Operators should not edit generated files by hand. See the runbook for the rollout procedure.

## [tls]

### tls.cert_file

Compiled-in default: `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.pem`.

Unknown keys are ignored with a warning. The service keeps its state in an append-only journal and rebuilds the index on start. Every entry is validated before it is written. Keys are compared case-sensitively. Every entry is validated before it is written. This section is kept for historical reasons and may be removed in a later revision.

The default is deliberately conservative. This section is kept for historical reasons and may be removed in a later revision. This section is kept for historical reasons and may be removed in a later revision. Unknown keys are ignored with a warning. Unknown keys are ignored with a warning.

Seen in practice: `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.pem` (prod/apac-south), `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.pem` (dev/us-east), `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.pem` (staging/apac-south), `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.pem` (staging/apac-south).

This section is kept for historical reasons and may be removed in a later revision. This section is kept for historical reasons and may be removed in a later revision. See the runbook for the rollout procedure. This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace.

### tls.key_file

Compiled-in default: `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key`.

This section is kept for historical reasons and may be removed in a later revision. Retries are bounded and jittered. This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace. This section is kept for historical reasons and may be removed in a later revision. Operators should not edit generated files by hand.

See the runbook for the rollout procedure. See the runbook for the rollout procedure. Retries are bounded and jittered. Operators should not edit generated files by hand. Every entry is validated before it is written.

Seen in practice: `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key` (dev/eu-central), `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key` (staging/us-east), `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key` (dev/us-east), `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key` (staging/eu-west).

A value set here applies only after the next reload. Retries are bounded and jittered. Retries are bounded and jittered. Operators should not edit generated files by hand. Every entry is validated before it is written.

### tls.min_version

Compiled-in default: `1.2`.

A value set here applies only after the next reload. Every entry is validated before it is written. Retries are bounded and jittered. The reader tolerates trailing whitespace. See the runbook for the rollout procedure. Every entry is validated before it is written.

See the runbook for the rollout procedure. A value set here applies only after the next reload. The service keeps its state in an append-only journal and rebuilds the index on start. Operators should not edit generated files by hand. Keys are compared case-sensitively.

Seen in practice: `1.3` (dev/us-east), `1.3` (staging/eu-central), `1.2` (dev/us-east), `1.2` (dev/us-east).

Keys are compared case-sensitively. The default is deliberately conservative. The reader tolerates trailing whitespace. The service keeps its state in an append-only journal and rebuilds the index on start. This section is kept for historical reasons and may be removed in a later revision.

### tls.cipher_profile

Compiled-in default: `intermediate`.

The default is deliberately conservative. Keys are compared case-sensitively. Every entry is validated before it is written. The default is deliberately conservative. The service keeps its state in an append-only journal and rebuilds the index on start. Keys are compared case-sensitively.

A value set here applies only after the next reload. The service keeps its state in an append-only journal and rebuilds the index on start. Unknown keys are ignored with a warning. Retries are bounded and jittered. A value set here applies only after the next reload.

Seen in practice: `intermediate` (canary/eu-west), `modern` (staging/eu-central), `intermediate` (prod/eu-central), `modern` (canary/apac-south).

Unknown keys are ignored with a warning. The default is deliberately conservative. Every entry is validated before it is written. See the runbook for the rollout procedure. This section is kept for historical reasons and may be removed in a later revision.

## [queue]

### queue.prefetch

Compiled-in default: `3`.

See the runbook for the rollout procedure. Retries are bounded and jittered. The service keeps its state in an append-only journal and rebuilds the index on start. The service keeps its state in an append-only journal and rebuilds the index on start. This section is kept for historical reasons and may be removed in a later revision. Retries are bounded and jittered.

The service keeps its state in an append-only journal and rebuilds the index on start. The service keeps its state in an append-only journal and rebuilds the index on start. The service keeps its state in an append-only journal and rebuilds the index on start. The reader tolerates trailing whitespace. The reader tolerates trailing whitespace.

Seen in practice: `4` (dev/apac-south), `64` (prod/eu-central), `256` (staging/us-east), `48` (staging/eu-west).

See the runbook for the rollout procedure. Keys are compared case-sensitively. Unknown keys are ignored with a warning. The service keeps its state in an append-only journal and rebuilds the index on start. Unknown keys are ignored with a warning.

### queue.visibility_s

Compiled-in default: `90`.

Keys are compared case-sensitively. Every entry is validated before it is written. Keys are compared case-sensitively. The reader tolerates trailing whitespace. See the runbook for the rollout procedure. See the runbook for the rollout procedure.

The service keeps its state in an append-only journal and rebuilds the index on start. The service keeps its state in an append-only journal and rebuilds the index on start. Keys are compared case-sensitively. A value set here applies only after the next reload. Unknown keys are ignored with a warning.

Seen in practice: `120` (canary/eu-central), `600` (dev/us-east), `60` (canary/apac-south), `60` (staging/eu-central).

The default is deliberately conservative. The service keeps its state in an append-only journal and rebuilds the index on start. The default is deliberately conservative. This section is kept for historical reasons and may be removed in a later revision. This section is kept for historical reasons and may be removed in a later revision.

### queue.dead_letter

Compiled-in default: `off`.

A value set here applies only after the next reload. Every entry is validated before it is written. Unknown keys are ignored with a warning. A value set here applies only after the next reload. This section is kept for historical reasons and may be removed in a later revision. Retries are bounded and jittered.

See the runbook for the rollout procedure. The default is deliberately conservative. Retries are bounded and jittered. Unknown keys are ignored with a warning. See the runbook for the rollout procedure.

Seen in practice: `on` (canary/apac-south), `off` (dev/eu-central), `on` (staging/apac-south), `on` (dev/us-east).

This section is kept for historical reasons and may be removed in a later revision. This section is kept for historical reasons and may be removed in a later revision. This section is kept for historical reasons and may be removed in a later revision. Operators should not edit generated files by hand. Retries are bounded and jittered.

### queue.batch_size

Compiled-in default: `2`.

A value set here applies only after the next reload. The default is deliberately conservative. A value set here applies only after the next reload. The service keeps its state in an append-only journal and rebuilds the index on start. The default is deliberately conservative. Every entry is validated before it is written.

Every entry is validated before it is written. Keys are compared case-sensitively. This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace. The reader tolerates trailing whitespace.

Seen in practice: `32` (staging/apac-south), `48` (dev/us-east), `10` (staging/apac-south), `10` (dev/apac-south).

Retries are bounded and jittered. Operators should not edit generated files by hand. Every entry is validated before it is written. Unknown keys are ignored with a warning. Keys are compared case-sensitively.

## [limits]

### limits.rps

Compiled-in default: `10`.

Keys are compared case-sensitively. Keys are compared case-sensitively. The default is deliberately conservative. The default is deliberately conservative. The service keeps its state in an append-only journal and rebuilds the index on start. Keys are compared case-sensitively.

Unknown keys are ignored with a warning. Operators should not edit generated files by hand. Retries are bounded and jittered. Retries are bounded and jittered. This section is kept for historical reasons and may be removed in a later revision.

Seen in practice: `1024` (dev/us-east), `24` (canary/eu-central), `16` (dev/eu-west), `256` (staging/apac-south).

Every entry is validated before it is written. See the runbook for the rollout procedure. The reader tolerates trailing whitespace. Retries are bounded and jittered. The default is deliberately conservative.

### limits.burst

Compiled-in default: `2048`.

Operators should not edit generated files by hand. A value set here applies only after the next reload. See the runbook for the rollout procedure. Retries are bounded and jittered. Retries are bounded and jittered. Every entry is validated before it is written.

The reader tolerates trailing whitespace. This section is kept for historical reasons and may be removed in a later revision. Unknown keys are ignored with a warning. This section is kept for historical reasons and may be removed in a later revision. The default is deliberately conservative.

Seen in practice: `64` (staging/apac-south), `6` (dev/eu-west), `10` (staging/eu-west), `4` (prod/eu-west).

This section is kept for historical reasons and may be removed in a later revision. The default is deliberately conservative. A value set here applies only after the next reload. The default is deliberately conservative. This section is kept for historical reasons and may be removed in a later revision.

### limits.concurrent_exports

Compiled-in default: `6`.

Unknown keys are ignored with a warning. See the runbook for the rollout procedure. See the runbook for the rollout procedure. Unknown keys are ignored with a warning. Every entry is validated before it is written. Keys are compared case-sensitively.

The default is deliberately conservative. The service keeps its state in an append-only journal and rebuilds the index on start. Keys are compared case-sensitively. Retries are bounded and jittered. Operators should not edit generated files by hand.

Seen in practice: `20` (staging/eu-central), `128` (canary/eu-west), `3` (dev/eu-west), `4096` (canary/apac-south).

The service keeps its state in an append-only journal and rebuilds the index on start. See the runbook for the rollout procedure. Retries are bounded and jittered. Unknown keys are ignored with a warning. This section is kept for historical reasons and may be removed in a later revision.

### limits.upload_mb

Compiled-in default: `16`.

Keys are compared case-sensitively. Retries are bounded and jittered. Every entry is validated before it is written. Operators should not edit generated files by hand. Unknown keys are ignored with a warning. Keys are compared case-sensitively.

Operators should not edit generated files by hand. See the runbook for the rollout procedure. This section is kept for historical reasons and may be removed in a later revision. Retries are bounded and jittered. Keys are compared case-sensitively.

Seen in practice: `256` (dev/eu-central), `3` (canary/us-east), `8` (canary/apac-south), `8` (dev/eu-west).

This section is kept for historical reasons and may be removed in a later revision. Retries are bounded and jittered. Every entry is validated before it is written. Unknown keys are ignored with a warning. Every entry is validated before it is written.

