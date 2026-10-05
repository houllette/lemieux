# Key reference

Every key the loader understands, its section, and the value it takes when no layer sets it. These documented fallbacks are the loader's compiled-in defaults, not what any target runs with.

## [http]

### http.request_timeout_ms

Compiled-in default: `1500`.

This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace. This section is kept for historical reasons and may be removed in a later revision. Keys are compared case-sensitively. The reader tolerates trailing whitespace. Operators should not edit generated files by hand.

The default is deliberately conservative. The reader tolerates trailing whitespace. Unknown keys are ignored with a warning. Retries are bounded and jittered. This section is kept for historical reasons and may be removed in a later revision.

Seen in practice: `1000` (staging/eu-central), `1000` (staging/apac-south), `500` (prod/apac-south), `750` (staging/eu-central).

See the runbook for the rollout procedure. The reader tolerates trailing whitespace. Unknown keys are ignored with a warning. Keys are compared case-sensitively. A value set here applies only after the next reload.

### http.max_body_bytes

Compiled-in default: `2097152`.

The reader tolerates trailing whitespace. Operators should not edit generated files by hand. Retries are bounded and jittered. A value set here applies only after the next reload. Every entry is validated before it is written. The reader tolerates trailing whitespace.

A value set here applies only after the next reload. This section is kept for historical reasons and may be removed in a later revision. A value set here applies only after the next reload. The reader tolerates trailing whitespace. Operators should not edit generated files by hand.

Seen in practice: `1048576` (staging/us-east), `8388608` (staging/us-east), `4194304` (prod/eu-central), `2097152` (staging/eu-west).

Retries are bounded and jittered. A value set here applies only after the next reload. This section is kept for historical reasons and may be removed in a later revision. A value set here applies only after the next reload. The default is deliberately conservative.

### http.keepalive_s

Compiled-in default: `120`.

Retries are bounded and jittered. The service keeps its state in an append-only journal and rebuilds the index on start. See the runbook for the rollout procedure. Every entry is validated before it is written. Operators should not edit generated files by hand. The service keeps its state in an append-only journal and rebuilds the index on start.

Keys are compared case-sensitively. The default is deliberately conservative. A value set here applies only after the next reload. Every entry is validated before it is written. A value set here applies only after the next reload.

Seen in practice: `300` (prod/us-east), `900` (prod/eu-west), `600` (dev/us-east), `90` (canary/us-east).

Keys are compared case-sensitively. Operators should not edit generated files by hand. Retries are bounded and jittered. The reader tolerates trailing whitespace. Every entry is validated before it is written.

### http.workers

Compiled-in default: `10`.

This section is kept for historical reasons and may be removed in a later revision. Keys are compared case-sensitively. Retries are bounded and jittered. Keys are compared case-sensitively. Retries are bounded and jittered. See the runbook for the rollout procedure.

Retries are bounded and jittered. A value set here applies only after the next reload. Retries are bounded and jittered. See the runbook for the rollout procedure. Keys are compared case-sensitively.

Seen in practice: `12` (staging/eu-central), `40` (prod/apac-south), `512` (prod/eu-west), `10` (canary/eu-west).

Operators should not edit generated files by hand. The service keeps its state in an append-only journal and rebuilds the index on start. Every entry is validated before it is written. Operators should not edit generated files by hand. Unknown keys are ignored with a warning.

### http.compression

Compiled-in default: `on`.

See the runbook for the rollout procedure. See the runbook for the rollout procedure. Keys are compared case-sensitively. Every entry is validated before it is written. Retries are bounded and jittered. Retries are bounded and jittered.

Unknown keys are ignored with a warning. Operators should not edit generated files by hand. The reader tolerates trailing whitespace. This section is kept for historical reasons and may be removed in a later revision. Every entry is validated before it is written.

Seen in practice: `off` (staging/eu-central), `off` (prod/us-east), `on` (canary/eu-west), `off` (canary/apac-south).

Keys are compared case-sensitively. The default is deliberately conservative. Retries are bounded and jittered. See the runbook for the rollout procedure. Operators should not edit generated files by hand.

## [db]

### db.pool_size

Compiled-in default: `1024`.

Operators should not edit generated files by hand. A value set here applies only after the next reload. The default is deliberately conservative. The default is deliberately conservative. This section is kept for historical reasons and may be removed in a later revision. The default is deliberately conservative.

The reader tolerates trailing whitespace. Operators should not edit generated files by hand. Unknown keys are ignored with a warning. Every entry is validated before it is written. Keys are compared case-sensitively.

Seen in practice: `40` (prod/us-east), `20` (prod/apac-south), `20` (staging/us-east), `6` (staging/eu-west).

See the runbook for the rollout procedure. A value set here applies only after the next reload. Keys are compared case-sensitively. Retries are bounded and jittered. Every entry is validated before it is written.

### db.statement_timeout_ms

Compiled-in default: `12000`.

The reader tolerates trailing whitespace. Keys are compared case-sensitively. The default is deliberately conservative. The service keeps its state in an append-only journal and rebuilds the index on start. Keys are compared case-sensitively. Retries are bounded and jittered.

See the runbook for the rollout procedure. The reader tolerates trailing whitespace. Every entry is validated before it is written. The reader tolerates trailing whitespace. Operators should not edit generated files by hand.

Seen in practice: `12000` (dev/us-east), `12000` (staging/eu-central), `4500` (dev/apac-south), `1500` (dev/us-east).

Retries are bounded and jittered. Operators should not edit generated files by hand. See the runbook for the rollout procedure. This section is kept for historical reasons and may be removed in a later revision. A value set here applies only after the next reload.

### db.replica

Compiled-in default: `on`.

This section is kept for historical reasons and may be removed in a later revision. The service keeps its state in an append-only journal and rebuilds the index on start. The default is deliberately conservative. See the runbook for the rollout procedure. Every entry is validated before it is written. Every entry is validated before it is written.

Operators should not edit generated files by hand. See the runbook for the rollout procedure. Unknown keys are ignored with a warning. See the runbook for the rollout procedure. A value set here applies only after the next reload.

Seen in practice: `on` (prod/us-east), `off` (dev/us-east), `off` (prod/apac-south), `off` (canary/eu-west).

This section is kept for historical reasons and may be removed in a later revision. This section is kept for historical reasons and may be removed in a later revision. Every entry is validated before it is written. Retries are bounded and jittered. A value set here applies only after the next reload.

### db.retry_limit

Compiled-in default: `3`.

Unknown keys are ignored with a warning. See the runbook for the rollout procedure. The service keeps its state in an append-only journal and rebuilds the index on start. Every entry is validated before it is written. See the runbook for the rollout procedure. Unknown keys are ignored with a warning.

A value set here applies only after the next reload. The default is deliberately conservative. See the runbook for the rollout procedure. A value set here applies only after the next reload. The reader tolerates trailing whitespace.

Seen in practice: `20` (dev/eu-central), `32` (staging/eu-central), `48` (canary/apac-south), `20` (dev/eu-west).

See the runbook for the rollout procedure. The default is deliberately conservative. This section is kept for historical reasons and may be removed in a later revision. Retries are bounded and jittered. The default is deliberately conservative.

### db.ssl_mode

Compiled-in default: `prefer`.

The reader tolerates trailing whitespace. Unknown keys are ignored with a warning. See the runbook for the rollout procedure. Operators should not edit generated files by hand. Unknown keys are ignored with a warning. Operators should not edit generated files by hand.

Unknown keys are ignored with a warning. See the runbook for the rollout procedure. Every entry is validated before it is written. This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace.

Seen in practice: `require` (prod/eu-west), `verify-full` (staging/us-east), `prefer` (dev/eu-central), `prefer` (prod/eu-west).

A value set here applies only after the next reload. Every entry is validated before it is written. The reader tolerates trailing whitespace. Retries are bounded and jittered. Every entry is validated before it is written.

## [cache]

### cache.ttl_seconds

Compiled-in default: `300`.

See the runbook for the rollout procedure. See the runbook for the rollout procedure. A value set here applies only after the next reload. Operators should not edit generated files by hand. This section is kept for historical reasons and may be removed in a later revision. Retries are bounded and jittered.

A value set here applies only after the next reload. Unknown keys are ignored with a warning. Operators should not edit generated files by hand. See the runbook for the rollout procedure. Every entry is validated before it is written.

Seen in practice: `30` (dev/us-east), `30` (canary/eu-central), `90` (canary/eu-west), `60` (canary/eu-central).

Keys are compared case-sensitively. See the runbook for the rollout procedure. Unknown keys are ignored with a warning. A value set here applies only after the next reload. See the runbook for the rollout procedure.

### cache.max_entries

Compiled-in default: `1024`.

Every entry is validated before it is written. The service keeps its state in an append-only journal and rebuilds the index on start. The default is deliberately conservative. Unknown keys are ignored with a warning. The default is deliberately conservative. The default is deliberately conservative.

Every entry is validated before it is written. This section is kept for historical reasons and may be removed in a later revision. See the runbook for the rollout procedure. A value set here applies only after the next reload. The default is deliberately conservative.

Seen in practice: `24` (prod/us-east), `128` (staging/eu-central), `1024` (staging/us-east), `2048` (canary/us-east).

Unknown keys are ignored with a warning. Operators should not edit generated files by hand. Unknown keys are ignored with a warning. Keys are compared case-sensitively. Keys are compared case-sensitively.

### cache.backend

Compiled-in default: `memory`.

Keys are compared case-sensitively. This section is kept for historical reasons and may be removed in a later revision. Unknown keys are ignored with a warning. This section is kept for historical reasons and may be removed in a later revision. Retries are bounded and jittered. This section is kept for historical reasons and may be removed in a later revision.

Keys are compared case-sensitively. Retries are bounded and jittered. Unknown keys are ignored with a warning. Keys are compared case-sensitively. See the runbook for the rollout procedure.

Seen in practice: `redis-like` (dev/eu-central), `redis-like` (staging/eu-west), `disk` (canary/eu-west), `redis-like` (dev/eu-west).

A value set here applies only after the next reload. Operators should not edit generated files by hand. The service keeps its state in an append-only journal and rebuilds the index on start. Unknown keys are ignored with a warning. Keys are compared case-sensitively.

### cache.shard_count

Compiled-in default: `48`.

This section is kept for historical reasons and may be removed in a later revision. Every entry is validated before it is written. The default is deliberately conservative. See the runbook for the rollout procedure. Unknown keys are ignored with a warning. Keys are compared case-sensitively.

Every entry is validated before it is written. This section is kept for historical reasons and may be removed in a later revision. The default is deliberately conservative. The default is deliberately conservative. Every entry is validated before it is written.

Seen in practice: `128` (prod/eu-central), `6` (dev/eu-central), `512` (canary/us-east), `3` (prod/eu-central).

Keys are compared case-sensitively. This section is kept for historical reasons and may be removed in a later revision. A value set here applies only after the next reload. The default is deliberately conservative. This section is kept for historical reasons and may be removed in a later revision.

## [features]

### features.checkout_variant

Compiled-in default: `classic`.

Retries are bounded and jittered. Retries are bounded and jittered. Keys are compared case-sensitively. A value set here applies only after the next reload. The default is deliberately conservative. See the runbook for the rollout procedure.

Operators should not edit generated files by hand. The reader tolerates trailing whitespace. See the runbook for the rollout procedure. The default is deliberately conservative. Unknown keys are ignored with a warning.

Seen in practice: `classic` (prod/eu-central), `beta` (prod/eu-west), `compact` (staging/apac-south), `beta` (prod/eu-central).

Unknown keys are ignored with a warning. The reader tolerates trailing whitespace. The reader tolerates trailing whitespace. The service keeps its state in an append-only journal and rebuilds the index on start. Every entry is validated before it is written.

### features.search_engine

Compiled-in default: `lexical`.

Operators should not edit generated files by hand. Every entry is validated before it is written. Every entry is validated before it is written. Operators should not edit generated files by hand. Unknown keys are ignored with a warning. Unknown keys are ignored with a warning.

Keys are compared case-sensitively. Retries are bounded and jittered. Keys are compared case-sensitively. Operators should not edit generated files by hand. See the runbook for the rollout procedure.

Seen in practice: `lexical` (dev/eu-central), `lexical` (canary/apac-south), `vector` (prod/apac-south), `legacy` (staging/us-east).

The default is deliberately conservative. Every entry is validated before it is written. This section is kept for historical reasons and may be removed in a later revision. See the runbook for the rollout procedure. Operators should not edit generated files by hand.

### features.invoice_layout

Compiled-in default: `a4`.

Keys are compared case-sensitively. Every entry is validated before it is written. Operators should not edit generated files by hand. Keys are compared case-sensitively. Every entry is validated before it is written. The default is deliberately conservative.

Keys are compared case-sensitively. Every entry is validated before it is written. See the runbook for the rollout procedure. The default is deliberately conservative. Unknown keys are ignored with a warning.

Seen in practice: `detailed` (prod/apac-south), `a4` (canary/eu-west), `detailed` (canary/apac-south), `detailed` (canary/eu-central).

Retries are bounded and jittered. Retries are bounded and jittered. The default is deliberately conservative. Keys are compared case-sensitively. See the runbook for the rollout procedure.

### features.beta_banner

Compiled-in default: `off`.

Every entry is validated before it is written. Unknown keys are ignored with a warning. The reader tolerates trailing whitespace. Unknown keys are ignored with a warning. The default is deliberately conservative. Every entry is validated before it is written.

The service keeps its state in an append-only journal and rebuilds the index on start. This section is kept for historical reasons and may be removed in a later revision. A value set here applies only after the next reload. Keys are compared case-sensitively. Unknown keys are ignored with a warning.

Seen in practice: `on` (canary/apac-south), `off` (dev/apac-south), `off` (staging/us-east), `off` (staging/eu-west).

The service keeps its state in an append-only journal and rebuilds the index on start. Every entry is validated before it is written. Keys are compared case-sensitively. Retries are bounded and jittered. A value set here applies only after the next reload.

## [logging]

### logging.sink

Compiled-in default: `@sinks/legacy`.

Unknown keys are ignored with a warning. The service keeps its state in an append-only journal and rebuilds the index on start. A value set here applies only after the next reload. The reader tolerates trailing whitespace. Every entry is validated before it is written. See the runbook for the rollout procedure.

This section is kept for historical reasons and may be removed in a later revision. The default is deliberately conservative. Every entry is validated before it is written. The reader tolerates trailing whitespace. Operators should not edit generated files by hand.

Seen in practice: `@sinks/archive` (prod/eu-central), `@sinks/archive` (prod/eu-west), `@sinks/legacy` (staging/eu-west), `@sinks/us-collector` (staging/apac-south).

The default is deliberately conservative. This section is kept for historical reasons and may be removed in a later revision. Every entry is validated before it is written. Keys are compared case-sensitively. A value set here applies only after the next reload.

### logging.level

Compiled-in default: `debug`.

Keys are compared case-sensitively. Unknown keys are ignored with a warning. A value set here applies only after the next reload. The service keeps its state in an append-only journal and rebuilds the index on start. This section is kept for historical reasons and may be removed in a later revision. Operators should not edit generated files by hand.

Every entry is validated before it is written. The reader tolerates trailing whitespace. Operators should not edit generated files by hand. Keys are compared case-sensitively. Unknown keys are ignored with a warning.

Seen in practice: `debug` (dev/eu-central), `warn` (dev/eu-west), `error` (prod/apac-south), `debug` (dev/eu-central).

See the runbook for the rollout procedure. Keys are compared case-sensitively. See the runbook for the rollout procedure. A value set here applies only after the next reload. The service keeps its state in an append-only journal and rebuilds the index on start.

### logging.sample_rate

Compiled-in default: `0.01`.

Keys are compared case-sensitively. This section is kept for historical reasons and may be removed in a later revision. A value set here applies only after the next reload. This section is kept for historical reasons and may be removed in a later revision. Operators should not edit generated files by hand. Operators should not edit generated files by hand.

The default is deliberately conservative. Every entry is validated before it is written. See the runbook for the rollout procedure. Retries are bounded and jittered. The default is deliberately conservative.

Seen in practice: `0.1` (prod/us-east), `1.0` (canary/eu-west), `0.5` (canary/apac-south), `1.0` (prod/eu-central).

This section is kept for historical reasons and may be removed in a later revision. See the runbook for the rollout procedure. Keys are compared case-sensitively. This section is kept for historical reasons and may be removed in a later revision. Keys are compared case-sensitively.

### logging.format

Compiled-in default: `logfmt`.

A value set here applies only after the next reload. Retries are bounded and jittered. The reader tolerates trailing whitespace. Every entry is validated before it is written. The default is deliberately conservative. See the runbook for the rollout procedure.

Unknown keys are ignored with a warning. Unknown keys are ignored with a warning. The service keeps its state in an append-only journal and rebuilds the index on start. The default is deliberately conservative. A value set here applies only after the next reload.

Seen in practice: `json` (prod/eu-west), `logfmt` (prod/apac-south), `json` (dev/eu-central), `logfmt` (prod/eu-central).

The service keeps its state in an append-only journal and rebuilds the index on start. Keys are compared case-sensitively. Operators should not edit generated files by hand. The default is deliberately conservative. Retries are bounded and jittered.

## [tls]

### tls.cert_file

Compiled-in default: `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.pem`.

Retries are bounded and jittered. The default is deliberately conservative. Every entry is validated before it is written. The service keeps its state in an append-only journal and rebuilds the index on start. Retries are bounded and jittered. Unknown keys are ignored with a warning.

Keys are compared case-sensitively. Every entry is validated before it is written. The default is deliberately conservative. This section is kept for historical reasons and may be removed in a later revision. The service keeps its state in an append-only journal and rebuilds the index on start.

Seen in practice: `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.pem` (staging/us-east), `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.pem` (staging/eu-west), `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.pem` (prod/eu-central), `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.pem` (dev/us-east).

The reader tolerates trailing whitespace. This section is kept for historical reasons and may be removed in a later revision. A value set here applies only after the next reload. Retries are bounded and jittered. Keys are compared case-sensitively.

### tls.key_file

Compiled-in default: `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key`.

A value set here applies only after the next reload. A value set here applies only after the next reload. The reader tolerates trailing whitespace. Unknown keys are ignored with a warning. This section is kept for historical reasons and may be removed in a later revision. Every entry is validated before it is written.

This section is kept for historical reasons and may be removed in a later revision. See the runbook for the rollout procedure. Operators should not edit generated files by hand. Keys are compared case-sensitively. The default is deliberately conservative.

Seen in practice: `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key` (prod/eu-west), `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key` (canary/us-east), `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key` (dev/us-east), `${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key` (canary/eu-central).

Every entry is validated before it is written. Operators should not edit generated files by hand. Every entry is validated before it is written. The default is deliberately conservative. See the runbook for the rollout procedure.

### tls.min_version

Compiled-in default: `1.3`.

Keys are compared case-sensitively. Retries are bounded and jittered. See the runbook for the rollout procedure. See the runbook for the rollout procedure. The service keeps its state in an append-only journal and rebuilds the index on start. The default is deliberately conservative.

Operators should not edit generated files by hand. See the runbook for the rollout procedure. Operators should not edit generated files by hand. The default is deliberately conservative. Unknown keys are ignored with a warning.

Seen in practice: `1.3` (dev/apac-south), `1.2` (staging/eu-west), `1.3` (canary/apac-south), `1.3` (staging/apac-south).

See the runbook for the rollout procedure. This section is kept for historical reasons and may be removed in a later revision. This section is kept for historical reasons and may be removed in a later revision. Unknown keys are ignored with a warning. See the runbook for the rollout procedure.

### tls.cipher_profile

Compiled-in default: `compat`.

The default is deliberately conservative. A value set here applies only after the next reload. Unknown keys are ignored with a warning. Keys are compared case-sensitively. Keys are compared case-sensitively. A value set here applies only after the next reload.

The default is deliberately conservative. See the runbook for the rollout procedure. This section is kept for historical reasons and may be removed in a later revision. Retries are bounded and jittered. The default is deliberately conservative.

Seen in practice: `modern` (staging/apac-south), `intermediate` (canary/eu-west), `compat` (canary/eu-west), `intermediate` (canary/eu-west).

See the runbook for the rollout procedure. This section is kept for historical reasons and may be removed in a later revision. Operators should not edit generated files by hand. A value set here applies only after the next reload. The service keeps its state in an append-only journal and rebuilds the index on start.

## [queue]

### queue.prefetch

Compiled-in default: `16`.

Retries are bounded and jittered. This section is kept for historical reasons and may be removed in a later revision. This section is kept for historical reasons and may be removed in a later revision. The default is deliberately conservative. The reader tolerates trailing whitespace. A value set here applies only after the next reload.

Retries are bounded and jittered. See the runbook for the rollout procedure. Every entry is validated before it is written. Operators should not edit generated files by hand. See the runbook for the rollout procedure.

Seen in practice: `4096` (staging/us-east), `64` (canary/apac-south), `32` (dev/us-east), `10` (staging/us-east).

Keys are compared case-sensitively. See the runbook for the rollout procedure. This section is kept for historical reasons and may be removed in a later revision. Keys are compared case-sensitively. This section is kept for historical reasons and may be removed in a later revision.

### queue.visibility_s

Compiled-in default: `15`.

The reader tolerates trailing whitespace. Keys are compared case-sensitively. Operators should not edit generated files by hand. Unknown keys are ignored with a warning. Unknown keys are ignored with a warning. A value set here applies only after the next reload.

Retries are bounded and jittered. The service keeps its state in an append-only journal and rebuilds the index on start. The default is deliberately conservative. See the runbook for the rollout procedure. See the runbook for the rollout procedure.

Seen in practice: `60` (staging/us-east), `60` (canary/eu-central), `15` (prod/apac-south), `120` (dev/eu-west).

Every entry is validated before it is written. The default is deliberately conservative. Retries are bounded and jittered. The default is deliberately conservative. See the runbook for the rollout procedure.

### queue.dead_letter

Compiled-in default: `off`.

Operators should not edit generated files by hand. Every entry is validated before it is written. A value set here applies only after the next reload. Unknown keys are ignored with a warning. The service keeps its state in an append-only journal and rebuilds the index on start. Every entry is validated before it is written.

Every entry is validated before it is written. A value set here applies only after the next reload. A value set here applies only after the next reload. Every entry is validated before it is written. The reader tolerates trailing whitespace.

Seen in practice: `on` (staging/apac-south), `on` (staging/eu-central), `on` (prod/eu-central), `on` (prod/us-east).

The reader tolerates trailing whitespace. A value set here applies only after the next reload. Every entry is validated before it is written. Unknown keys are ignored with a warning. This section is kept for historical reasons and may be removed in a later revision.

### queue.batch_size

Compiled-in default: `1024`.

This section is kept for historical reasons and may be removed in a later revision. Unknown keys are ignored with a warning. See the runbook for the rollout procedure. Retries are bounded and jittered. Every entry is validated before it is written. Keys are compared case-sensitively.

Keys are compared case-sensitively. Retries are bounded and jittered. This section is kept for historical reasons and may be removed in a later revision. Operators should not edit generated files by hand. See the runbook for the rollout procedure.

Seen in practice: `1024` (staging/eu-central), `3` (dev/us-east), `64` (dev/us-east), `12` (dev/eu-west).

The reader tolerates trailing whitespace. Retries are bounded and jittered. The reader tolerates trailing whitespace. Unknown keys are ignored with a warning. Retries are bounded and jittered.

## [limits]

### limits.rps

Compiled-in default: `512`.

A value set here applies only after the next reload. Unknown keys are ignored with a warning. The service keeps its state in an append-only journal and rebuilds the index on start. The reader tolerates trailing whitespace. Retries are bounded and jittered. See the runbook for the rollout procedure.

Operators should not edit generated files by hand. The reader tolerates trailing whitespace. The reader tolerates trailing whitespace. The default is deliberately conservative. Keys are compared case-sensitively.

Seen in practice: `256` (canary/eu-central), `10` (staging/eu-central), `32` (canary/us-east), `12` (prod/apac-south).

Retries are bounded and jittered. A value set here applies only after the next reload. The service keeps its state in an append-only journal and rebuilds the index on start. Retries are bounded and jittered. Retries are bounded and jittered.

### limits.burst

Compiled-in default: `2`.

Unknown keys are ignored with a warning. Keys are compared case-sensitively. Every entry is validated before it is written. A value set here applies only after the next reload. See the runbook for the rollout procedure. A value set here applies only after the next reload.

Operators should not edit generated files by hand. Operators should not edit generated files by hand. The reader tolerates trailing whitespace. Retries are bounded and jittered. The reader tolerates trailing whitespace.

Seen in practice: `12` (canary/eu-central), `128` (prod/apac-south), `2` (staging/us-east), `2048` (dev/eu-west).

A value set here applies only after the next reload. Every entry is validated before it is written. A value set here applies only after the next reload. Unknown keys are ignored with a warning. This section is kept for historical reasons and may be removed in a later revision.

### limits.concurrent_exports

Compiled-in default: `24`.

See the runbook for the rollout procedure. Operators should not edit generated files by hand. Unknown keys are ignored with a warning. See the runbook for the rollout procedure. This section is kept for historical reasons and may be removed in a later revision. The service keeps its state in an append-only journal and rebuilds the index on start.

Keys are compared case-sensitively. The service keeps its state in an append-only journal and rebuilds the index on start. See the runbook for the rollout procedure. See the runbook for the rollout procedure. This section is kept for historical reasons and may be removed in a later revision.

Seen in practice: `2` (dev/apac-south), `2` (canary/eu-west), `48` (canary/eu-west), `32` (dev/eu-central).

Unknown keys are ignored with a warning. Keys are compared case-sensitively. Every entry is validated before it is written. Unknown keys are ignored with a warning. A value set here applies only after the next reload.

### limits.upload_mb

Compiled-in default: `10`.

The service keeps its state in an append-only journal and rebuilds the index on start. See the runbook for the rollout procedure. The default is deliberately conservative. Keys are compared case-sensitively. See the runbook for the rollout procedure. The service keeps its state in an append-only journal and rebuilds the index on start.

Operators should not edit generated files by hand. Operators should not edit generated files by hand. Keys are compared case-sensitively. The reader tolerates trailing whitespace. See the runbook for the rollout procedure.

Seen in practice: `40` (prod/us-east), `8` (dev/eu-central), `256` (prod/us-east), `32` (dev/us-east).

See the runbook for the rollout procedure. A value set here applies only after the next reload. See the runbook for the rollout procedure. This section is kept for historical reasons and may be removed in a later revision. The service keeps its state in an append-only journal and rebuilds the index on start.

