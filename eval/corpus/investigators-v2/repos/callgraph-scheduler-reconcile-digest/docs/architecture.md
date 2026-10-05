# Architecture

This page was written for the 2025 layout and has not been fully updated.

## Digests

The reconcile job stores a `sha-like` digest (see `hash_algorithm` at the top of config/settings.conf).

The reader tolerates trailing whitespace. Retries are bounded and jittered. Unknown keys are ignored with a warning. Keys are compared case-sensitively.

## Scheduler

Jobs are wired in app/scheduler/cron.py.

Every entry is validated before it is written. A value set here applies only after the next reload. The default is deliberately conservative. A value set here applies only after the next reload.

