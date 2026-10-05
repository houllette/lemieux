# Key reference

Every key the loader understands, its section, and the value it takes when no layer sets it. These documented fallbacks are the loader's compiled-in defaults, not what any target runs with.

## [http]

### http.request_timeout_ms

Compiled-in default: `2000`.

Operators should not edit generated files by hand. Every entry is validated before it is written. The default is deliberately conservative. The service keeps its state in an append-only journal and rebuilds the index on start. The reader tolerates trailing whitespace. This section is kept for historical reasons and may be removed in a later revision.

Operators should not edit generated files by hand. Operators should not edit generated files by hand. This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace. This section is kept for historical reasons and may be removed in a later revision.

Seen in practice: `12000` (canary/eu-central), `12000` (dev/eu-central), `2000` (prod/us-east), `500` (staging/eu-central).

Operators should not edit generated files by hand. Keys are compared case-sensitively. See the runbook for the rollout procedure. A value set here applies only after the next reload. This section is kept for historical reasons and may be removed in a later revision.

### http.max_body_bytes

Compiled-in default: `4194304`.

Keys are compared case-sensitively. Unknown keys are ignored with a warning. Every entry is validated before it is written. Every entry is validated before it is written. A value set here applies only after the next reload. The default is deliberately conservative.

Unknown keys are ignored with a warning. See the runbook for the rollout procedure. Keys are compared case-sensitively. Keys are compared case-sensitively. This section is kept for historical reasons and may be removed in a later revision.

Seen in practice: `2097152` (dev/us-east), `8388608` (staging/eu-west), `2097152` (prod/apac-south), `8388608` (prod/apac-south).

Operators should not edit generated files by hand. A value set here applies only after the next reload. This section is kept for historical reasons and may be removed in a later revision. Retries are bounded and jittered. Unknown keys are ignored with a warning.

### http.keepalive_s

Compiled-in default: `120`.

Retries are bounded and jittered. The default is deliberately conservative. Unknown keys are ignored with a warning. Retries are bounded and jittered. Unknown keys are ignored with a warning. This section is kept for historical reasons and may be removed in a later revision.

The reader tolerates trailing whitespace. The default is deliberately conservative. The service keeps its state in an append-only journal and rebuilds the index on start. This section is kept for historical reasons and may be removed in a later revision. Every entry is validated before it is written.

Seen in practice: `30` (dev/apac-south), `1800` (canary/eu-central), `30` (canary/eu-west), `90` (canary/apac-south).

The service keeps its state in an append-only journal and rebuilds the index on start. Unknown keys are ignored with a warning. This section is kept for historical reasons and may be removed in a later revision. See the runbook for the rollout procedure. The reader tolerates trailing whitespace.

### http.workers

Compiled-in default: `1024`.

The default is deliberately conservative. Unknown keys are ignored with a warning. Operators should not edit generated files by hand. Every entry is validated before it is written. The service keeps its state in an append-only journal and rebuilds the index on start. Operators should not edit generated files by hand.

Every entry is validated before it is written. Retries are bounded and jittered. Retries are bounded and jittered. Retries are bounded and jittered. Keys are compared case-sensitively.

Seen in practice: `4` (canary/eu-central), `16` (canary/apac-south), `8` (prod/eu-central), `24` (staging/eu-west).

The reader tolerates trailing whitespace. The reader tolerates trailing whitespace. Keys are compared case-sensitively. The default is deliberately conservative. Operators should not edit generated files by hand.

### http.compression

Compiled-in default: `off`.

Operators should not edit generated files by hand. A value set here applies only after the next reload. The reader tolerates trailing whitespace. Unknown keys are ignored with a warning. The reader tolerates trailing whitespace. Keys are compared case-sensitively.

A value set here applies only after the next reload. A value set here applies only after the next reload. Retries are bounded and jittered. Operators should not edit generated files by hand. This section is kept for historical reasons and may be removed in a later revision.

Seen in practice: `off` (prod/apac-south), `on` (prod/eu-central), `on` (prod/us-east), `off` (dev/us-east).

The reader tolerates trailing whitespace. Keys are compared case-sensitively. A value set here applies only after the next reload. The service keeps its state in an append-only journal and rebuilds the index on start. Every entry is validated before it is written.

## [db]

### db.pool_size

Compiled-in default: `48`.

Operators should not edit generated files by hand. The reader tolerates trailing whitespace. See the runbook for the rollout procedure. The default is deliberately conservative. Retries are bounded and jittered. A value set here applies only after the next reload.

The reader tolerates trailing whitespace. Every entry is validated before it is written. The service keeps its state in an append-only journal and rebuilds the index on start. Every entry is validated before it is written. Operators should not edit generated files by hand.

Seen in practice: `256` (staging/eu-west), `16` (dev/eu-central), `4096` (dev/eu-central), `24` (dev/eu-central).

Every entry is validated before it is written. The service keeps its state in an append-only journal and rebuilds the index on start. Operators should not edit generated files by hand. Keys are compared case-sensitively. Unknown keys are ignored with a warning.

### db.statement_timeout_ms

Compiled-in default: `4500`.

Keys are compared case-sensitively. A value set here applies only after the next reload. See the runbook for the rollout procedure. A value set here applies only after the next reload. Operators should not edit generated files by hand. A value set here applies only after the next reload.

Operators should not edit generated files by hand. See the runbook for the rollout procedure. See the runbook for the rollout procedure. The default is deliberately conservative. The service keeps its state in an append-only journal and rebuilds the index on start.

Seen in practice: `3000` (canary/us-east), `12000` (staging/eu-west), `12000` (dev/eu-west), `250` (prod/eu-west).

The default is deliberately conservative. The reader tolerates trailing whitespace. The reader tolerates trailing whitespace. A value set here applies only after the next reload. Retries are bounded and jittered.

### db.replica

Compiled-in default: `off`.

Operators should not edit generated files by hand. A value set here applies only after the next reload. The service keeps its state in an append-only journal and rebuilds the index on start. See the runbook for the rollout procedure. The service keeps its state in an append-only journal and rebuilds the index on start. Operators should not edit generated files by hand.

Retries are bounded and jittered. The default is deliberately conservative. The default is deliberately conservative. Operators should not edit generated files by hand. This section is kept for historical reasons and may be removed in a later revision.

Seen in practice: `off` (canary/eu-central), `off` (prod/eu-central), `off` (prod/eu-central), `off` (dev/us-east).

Every entry is validated before it is written. Unknown keys are ignored with a warning. A value set here applies only after the next reload. A value set here applies only after the next reload. Keys are compared case-sensitively.

### db.retry_limit

Compiled-in default: `96`.

This section is kept for historical reasons and may be removed in a later revision. Every entry is validated before it is written. A value set here applies only after the next reload. A value set here applies only after the next reload. Every entry is validated before it is written. A value set here applies only after the next reload.

This section is kept for historical reasons and may be removed in a later revision. See the runbook for the rollout procedure. The default is deliberately conservative. Retries are bounded and jittered. The reader tolerates trailing whitespace.

Seen in practice: `6` (prod/eu-west), `8` (canary/eu-central), `64` (canary/eu-west), `20` (staging/apac-south).

Operators should not edit generated files by hand. The default is deliberately conservative. See the runbook for the rollout procedure. A value set here applies only after the next reload. A value set here applies only after the next reload.

### db.ssl_mode

Compiled-in default: `prefer`.

Every entry is validated before it is written. Unknown keys are ignored with a warning. Unknown keys are ignored with a warning. Every entry is validated before it is written. This section is kept for historical reasons and may be removed in a later revision. Keys are compared case-sensitively.

Keys are compared case-sensitively. Every entry is validated before it is written. The reader tolerates trailing whitespace. The service keeps its state in an append-only journal and rebuilds the index on start. Every entry is validated before it is written.

Seen in practice: `prefer` (prod/eu-central), `require` (prod/us-east), `verify-full` (canary/apac-south), `verify-full` (staging/eu-west).

Keys are compared case-sensitively. Keys are compared case-sensitively. Unknown keys are ignored with a warning. See the runbook for the rollout procedure. Every entry is validated before it is written.

## [cache]

### cache.ttl_seconds

Compiled-in default: `30`.

Keys are compared case-sensitively. Every entry is validated before it is written. A value set here applies only after the next reload. This section is kept for historical reasons and may be removed in a later revision. This section is kept for historical reasons and may be removed in a later revision. A value set here applies only after the next reload.

The service keeps its state in an append-only journal and rebuilds the index on start. A value set here applies only after the next reload. The reader tolerates trailing whitespace. The service keeps its state in an append-only journal and rebuilds the index on start. Retries are bounded and jittered.

Seen in practice: `300` (staging/eu-central), `120` (prod/apac-south), `60` (staging/apac-south), `90` (canary/eu-central).

Every entry is validated before it is written. Unknown keys are ignored with a warning. Every entry is validated before it is written. See the runbook for the rollout procedure. The service keeps its state in an append-only journal and rebuilds the index on start.

### cache.max_entries

Compiled-in default: `48`.

Retries are bounded and jittered. See the runbook for the rollout procedure. This section is kept for historical reasons and may be removed in a later revision. The service keeps its state in an append-only journal and rebuilds the index on start. The reader tolerates trailing whitespace. Keys are compared case-sensitively.

Unknown keys are ignored with a warning. The service keeps its state in an append-only journal and rebuilds the index on start. The reader tolerates trailing whitespace. Unknown keys are ignored with a warning. The service keeps its state in an append-only journal and rebuilds the index on start.

Seen in practice: `8` (dev/apac-south), `1024` (dev/us-east), `256` (prod/us-east), `1024` (staging/apac-south).

See the runbook for the rollout procedure. The default is deliberately conservative. A value set here applies only after the next reload. Operators should not edit generated files by hand. A value set here applies only after the next reload.

### cache.backend

Compiled-in default: `redis-like`.

The service keeps its state in an append-only journal and rebuilds the index on start. See the runbook for the rollout procedure. The reader tolerates trailing whitespace. Retries are bounded and jittered. The service keeps its state in an append-only journal and rebuilds the index on start. Operators should not edit generated files by hand.

Every entry is validated before it is written. Unknown keys are ignored with a warning. A value set here applies only after the next reload. This section is kept for historical reasons and may be removed in a later revision. A value set here applies only after the next reload.

Seen in practice: `memory` (staging/apac-south), `disk` (dev/eu-central), `tiered` (dev/eu-central), `disk` (canary/eu-central).

Operators should not edit generated files by hand. Keys are compared case-sensitively. See the runbook for the rollout procedure. Every entry is validated before it is written. A value set here applies only after the next reload.

### cache.shard_count

Compiled-in default: `2048`.

The reader tolerates trailing whitespace. See the runbook for the rollout procedure. See the runbook for the rollout procedure. Unknown keys are ignored with a warning. The reader tolerates trailing whitespace. See the runbook for the rollout procedure.

This section is kept for historical reasons and may be removed in a later revision. Unknown keys are ignored with a warning. Every entry is validated before it is written. Keys are compared case-sensitively. See the runbook for the rollout procedure.

Seen in practice: `10` (dev/apac-south), `10` (staging/us-east), `10` (prod/eu-west), `128` (prod/eu-central).

This section is kept for historical reasons and may be removed in a later revision. This section is kept for historical reasons and may be removed in a later revision. Retries are bounded and jittered. A value set here applies only after the next reload. This section is kept for historical reasons and may be removed in a later revision.

## [features]

### features.checkout_variant

Compiled-in default: `compact`.

Every entry is validated before it is written. A value set here applies only after the next reload. Keys are compared case-sensitively. Operators should not edit generated files by hand. See the runbook for the rollout procedure. Keys are compared case-sensitively.

Every entry is validated before it is written. The default is deliberately conservative. The reader tolerates trailing whitespace. This section is kept for historical reasons and may be removed in a later revision. Unknown keys are ignored with a warning.

Seen in practice: `beta` (prod/eu-central), `compact` (prod/eu-west), `guided` (prod/eu-west), `split` (prod/eu-central).

The service keeps its state in an append-only journal and rebuilds the index on start. This section is kept for historical reasons and may be removed in a later revision. This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace. The reader tolerates trailing whitespace.

### features.search_engine

Compiled-in default: `hybrid`.

The reader tolerates trailing whitespace. Every entry is validated before it is written. Operators should not edit generated files by hand. Every entry is validated before it is written. Retries are bounded and jittered. Keys are compared case-sensitively.

Operators should not edit generated files by hand. Every entry is validated before it is written. A value set here applies only after the next reload. Keys are compared case-sensitively. Keys are compared case-sensitively.

Seen in practice: `lexical` (staging/eu-central), `vector` (dev/us-east), `lexical` (prod/eu-west), `legacy` (canary/us-east).

The reader tolerates trailing whitespace. This section is kept for historical reasons and may be removed in a later revision. Every entry is validated before it is written. Unknown keys are ignored with a warning. A value set here applies only after the next reload.

### features.invoice_layout

Compiled-in default: `letter`.

The default is deliberately conservative. Operators should not edit generated files by hand. Unknown keys are ignored with a warning. The service keeps its state in an append-only journal and rebuilds the index on start. Every entry is validated before it is written. Keys are compared case-sensitively.

Keys are compared case-sensitively. Retries are bounded and jittered. Unknown keys are ignored with a warning. A value set here applies only after the next reload. The default is deliberately conservative.

Seen in practice: `detailed` (prod/apac-south), `a4` (staging/eu-central), `a4` (staging/us-east), `a4` (prod/eu-west).

Operators should not edit generated files by hand. Operators should not edit generated files by hand. This section is kept for historical reasons and may be removed in a later revision. Keys are compared case-sensitively. Operators should not edit generated files by hand.

### features.beta_banner

Compiled-in default: `on`.

Keys are compared case-sensitively. Keys are compared case-sensitively. Operators should not edit generated files by hand. The service keeps its state in an append-only journal and rebuilds the index on start. Operators should not edit generated files by hand. Unknown keys are ignored with a warning.

Unknown keys are ignored with a warning. See the runbook for the rollout procedure. The default is deliberately conservative. Unknown keys are ignored with a warning. A value set here applies only after the next reload.

Seen in practice: `off` (staging/us-east), `off` (prod/apac-south), `off` (dev/us-east), `on` (canary/apac-south).

Retries are bounded and jittered. Keys are compared case-sensitively. Operators should not edit generated files by hand. Unknown keys are ignored with a warning. Retries are bounded and jittered.

## [logging]

### logging.sink

Compiled-in default: `@sinks/secondary`.

Every entry is validated before it is written. The service keeps its state in an append-only journal and rebuilds the index on start. See the runbook for the rollout procedure. Operators should not edit generated files by hand. The service keeps its state in an append-only journal and rebuilds the index on start. The default is deliberately conservative.

Every entry is validated before it is written. Keys are compared case-sensitively. Operators should not edit generated files by hand. The default is deliberately conservative. Operators should not edit generated files by hand.

Seen in practice: `@sinks/archive` (prod/us-east), `@sinks/primary` (staging/eu-west), `@sinks/apac-collector` (dev/apac-south), `@sinks/secondary` (prod/apac-south).

Operators should not edit generated files by hand. The reader tolerates trailing whitespace. The service keeps its state in an append-only journal and rebuilds the index on start. A value set here applies only after the next reload. See the runbook for the rollout procedure.

### logging.level

Compiled-in default: `warn`.

Retries are bounded and jittered. Retries are bounded and jittered. This section is kept for historical reasons and may be removed in a later revision. The service keeps its state in an append-only journal and rebuilds the index on start. Retries are bounded and jittered. Keys are compared case-sensitively.

The default is deliberately conservative. Retries are bounded and jittered. Retries are bounded and jittered. Retries are bounded and jittered. See the runbook for the rollout procedure.

Seen in practice: `debug` (canary/eu-west), `error` (dev/apac-south), `warn` (staging/us-east), `info` (prod/eu-west).

This section is kept for historical reasons and may be removed in a later revision. Keys are compared case-sensitively. A value set here applies only after the next reload. The service keeps its state in an append-only journal and rebuilds the index on start. Retries are bounded and jittered.

### logging.sample_rate

Compiled-in default: `0.01`.

Operators should not edit generated files by hand. A value set here applies only after the next reload. Keys are compared case-sensitively. Retries are bounded and jittered. Retries are bounded and jittered. Every entry is validated before it is written.

This section is kept for historical reasons and may be removed in a later revision. Every entry is validated before it is written. This section is kept for historical reasons and may be removed in a later revision. Every entry is validated before it is written. The service keeps its state in an append-only journal and rebuilds the index on start.

Seen in practice: `0.5` (canary/apac-south), `0.1` (prod/eu-central), `0.05` (staging/us-east), `0.25` (staging/eu-central).

Retries are bounded and jittered. Every entry is validated before it is written. A value set here applies only after the next reload. The reader tolerates trailing whitespace. Operators should not edit generated files by hand.

### logging.format

Compiled-in default: `text`.

The reader tolerates trailing whitespace. Every entry is validated before it is written. Retries are bounded and jittered. Unknown keys are ignored with a warning. The service keeps its state in an append-only journal and rebuilds the index on start. Every entry is validated before it is written.

Unknown keys are ignored with a warning. Operators should not edit generated files by hand. Every entry is validated before it is written. The reader tolerates trailing whitespace. A value set here applies only after the next reload.

Seen in practice: `text` (staging/eu-west), `logfmt` (canary/us-east), `logfmt` (dev/eu-central), `json` (prod/eu-central).

Operators should not edit generated files by hand. Operators should not edit generated files by hand. Operators should not edit generated files by hand. Retries are bounded and jittered. A value set here applies only after the next reload.

## [tls]

### tls.cert_file

Compiled-in default: `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.pem`.

A value set here applies only after the next reload. This section is kept for historical reasons and may be removed in a later revision. Retries are bounded and jittered. Retries are bounded and jittered. Every entry is validated before it is written. Keys are compared case-sensitively.

The default is deliberately conservative. See the runbook for the rollout procedure. Operators should not edit generated files by hand. See the runbook for the rollout procedure. This section is kept for historical reasons and may be removed in a later revision.

Seen in practice: `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.pem` (prod/eu-central), `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.pem` (dev/eu-west), `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.pem` (prod/eu-west), `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.pem` (dev/eu-central).

The reader tolerates trailing whitespace. Keys are compared case-sensitively. Unknown keys are ignored with a warning. The reader tolerates trailing whitespace. A value set here applies only after the next reload.

### tls.key_file

Compiled-in default: `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key`.

This section is kept for historical reasons and may be removed in a later revision. A value set here applies only after the next reload. See the runbook for the rollout procedure. The service keeps its state in an append-only journal and rebuilds the index on start. The default is deliberately conservative. Keys are compared case-sensitively.

Unknown keys are ignored with a warning. Every entry is validated before it is written. Retries are bounded and jittered. See the runbook for the rollout procedure. The default is deliberately conservative.

Seen in practice: `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key` (dev/eu-west), `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key` (dev/us-east), `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key` (prod/eu-west), `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key` (staging/us-east).

This section is kept for historical reasons and may be removed in a later revision. Keys are compared case-sensitively. Unknown keys are ignored with a warning. The default is deliberately conservative. See the runbook for the rollout procedure.

### tls.min_version

Compiled-in default: `1.2`.

The reader tolerates trailing whitespace. See the runbook for the rollout procedure. Every entry is validated before it is written. See the runbook for the rollout procedure. A value set here applies only after the next reload. This section is kept for historical reasons and may be removed in a later revision.

A value set here applies only after the next reload. A value set here applies only after the next reload. See the runbook for the rollout procedure. Keys are compared case-sensitively. Operators should not edit generated files by hand.

Seen in practice: `1.2` (prod/eu-central), `1.2` (prod/us-east), `1.2` (canary/us-east), `1.2` (canary/apac-south).

The default is deliberately conservative. Every entry is validated before it is written. The reader tolerates trailing whitespace. Unknown keys are ignored with a warning. Operators should not edit generated files by hand.

### tls.cipher_profile

Compiled-in default: `intermediate`.

Every entry is validated before it is written. Keys are compared case-sensitively. The reader tolerates trailing whitespace. This section is kept for historical reasons and may be removed in a later revision. See the runbook for the rollout procedure. This section is kept for historical reasons and may be removed in a later revision.

See the runbook for the rollout procedure. The service keeps its state in an append-only journal and rebuilds the index on start. See the runbook for the rollout procedure. See the runbook for the rollout procedure. The service keeps its state in an append-only journal and rebuilds the index on start.

Seen in practice: `modern` (staging/eu-west), `compat` (staging/eu-central), `compat` (canary/apac-south), `intermediate` (dev/apac-south).

Every entry is validated before it is written. Every entry is validated before it is written. See the runbook for the rollout procedure. Retries are bounded and jittered. A value set here applies only after the next reload.

## [queue]

### queue.prefetch

Compiled-in default: `1024`.

The service keeps its state in an append-only journal and rebuilds the index on start. Keys are compared case-sensitively. Every entry is validated before it is written. This section is kept for historical reasons and may be removed in a later revision. Retries are bounded and jittered. Retries are bounded and jittered.

See the runbook for the rollout procedure. A value set here applies only after the next reload. See the runbook for the rollout procedure. Every entry is validated before it is written. Retries are bounded and jittered.

Seen in practice: `32` (prod/eu-west), `32` (staging/apac-south), `10` (canary/apac-south), `4` (prod/eu-central).

A value set here applies only after the next reload. The reader tolerates trailing whitespace. Retries are bounded and jittered. The service keeps its state in an append-only journal and rebuilds the index on start. Keys are compared case-sensitively.

### queue.visibility_s

Compiled-in default: `900`.

A value set here applies only after the next reload. The reader tolerates trailing whitespace. Keys are compared case-sensitively. See the runbook for the rollout procedure. Unknown keys are ignored with a warning. This section is kept for historical reasons and may be removed in a later revision.

Operators should not edit generated files by hand. The reader tolerates trailing whitespace. Keys are compared case-sensitively. Keys are compared case-sensitively. The reader tolerates trailing whitespace.

Seen in practice: `60` (canary/eu-west), `45` (canary/eu-west), `90` (staging/eu-central), `30` (canary/us-east).

A value set here applies only after the next reload. Operators should not edit generated files by hand. See the runbook for the rollout procedure. Every entry is validated before it is written. The default is deliberately conservative.

### queue.dead_letter

Compiled-in default: `on`.

Retries are bounded and jittered. A value set here applies only after the next reload. Keys are compared case-sensitively. A value set here applies only after the next reload. This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace.

Operators should not edit generated files by hand. This section is kept for historical reasons and may be removed in a later revision. See the runbook for the rollout procedure. A value set here applies only after the next reload. The default is deliberately conservative.

Seen in practice: `on` (dev/eu-central), `on` (prod/eu-central), `on` (canary/us-east), `on` (staging/eu-west).

A value set here applies only after the next reload. This section is kept for historical reasons and may be removed in a later revision. A value set here applies only after the next reload. A value set here applies only after the next reload. The default is deliberately conservative.

### queue.batch_size

Compiled-in default: `64`.

The default is deliberately conservative. This section is kept for historical reasons and may be removed in a later revision. Every entry is validated before it is written. See the runbook for the rollout procedure. See the runbook for the rollout procedure. Unknown keys are ignored with a warning.

This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace. The service keeps its state in an append-only journal and rebuilds the index on start. See the runbook for the rollout procedure. Retries are bounded and jittered.

Seen in practice: `3` (dev/eu-west), `6` (staging/us-east), `512` (prod/eu-west), `512` (dev/eu-west).

Unknown keys are ignored with a warning. Unknown keys are ignored with a warning. See the runbook for the rollout procedure. The service keeps its state in an append-only journal and rebuilds the index on start. Unknown keys are ignored with a warning.

## [limits]

### limits.rps

Compiled-in default: `4096`.

Keys are compared case-sensitively. The reader tolerates trailing whitespace. This section is kept for historical reasons and may be removed in a later revision. A value set here applies only after the next reload. Operators should not edit generated files by hand. The service keeps its state in an append-only journal and rebuilds the index on start.

Every entry is validated before it is written. Operators should not edit generated files by hand. Retries are bounded and jittered. The default is deliberately conservative. The service keeps its state in an append-only journal and rebuilds the index on start.

Seen in practice: `64` (prod/us-east), `10` (canary/us-east), `128` (dev/apac-south), `4096` (staging/apac-south).

The default is deliberately conservative. This section is kept for historical reasons and may be removed in a later revision. Operators should not edit generated files by hand. Keys are compared case-sensitively. A value set here applies only after the next reload.

### limits.burst

Compiled-in default: `4096`.

The service keeps its state in an append-only journal and rebuilds the index on start. The default is deliberately conservative. This section is kept for historical reasons and may be removed in a later revision. See the runbook for the rollout procedure. The default is deliberately conservative. Operators should not edit generated files by hand.

Every entry is validated before it is written. The default is deliberately conservative. The service keeps its state in an append-only journal and rebuilds the index on start. A value set here applies only after the next reload. Keys are compared case-sensitively.

Seen in practice: `40` (dev/eu-west), `12` (prod/eu-west), `10` (canary/eu-central), `8` (staging/eu-west).

Every entry is validated before it is written. The default is deliberately conservative. Operators should not edit generated files by hand. This section is kept for historical reasons and may be removed in a later revision. Every entry is validated before it is written.

### limits.concurrent_exports

Compiled-in default: `24`.

A value set here applies only after the next reload. The default is deliberately conservative. Unknown keys are ignored with a warning. A value set here applies only after the next reload. Retries are bounded and jittered. This section is kept for historical reasons and may be removed in a later revision.

The default is deliberately conservative. A value set here applies only after the next reload. The default is deliberately conservative. Unknown keys are ignored with a warning. Every entry is validated before it is written.

Seen in practice: `20` (staging/eu-central), `16` (staging/us-east), `4096` (canary/apac-south), `64` (staging/apac-south).

The default is deliberately conservative. Retries are bounded and jittered. Keys are compared case-sensitively. Unknown keys are ignored with a warning. The default is deliberately conservative.

### limits.upload_mb

Compiled-in default: `32`.

This section is kept for historical reasons and may be removed in a later revision. Every entry is validated before it is written. Retries are bounded and jittered. Operators should not edit generated files by hand. The default is deliberately conservative. Operators should not edit generated files by hand.

A value set here applies only after the next reload. Keys are compared case-sensitively. The reader tolerates trailing whitespace. The reader tolerates trailing whitespace. Every entry is validated before it is written.

Seen in practice: `40` (canary/eu-central), `96` (prod/apac-south), `128` (canary/eu-central), `8` (dev/eu-central).

Unknown keys are ignored with a warning. See the runbook for the rollout procedure. Operators should not edit generated files by hand. Every entry is validated before it is written. This section is kept for historical reasons and may be removed in a later revision.

