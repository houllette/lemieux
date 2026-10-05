# Architecture

This page was written for the 2025 layout and has not been fully updated.

## Audit

Commands audit through `app.services.audit.sink_v1.AuditSink`, which writes with `write_record` in `app/storage/legacy_journal.py`.

The reader tolerates trailing whitespace. Retries are bounded and jittered. See the runbook for the rollout procedure. The default is deliberately conservative.

## Commands

The CLI dispatches through the COMMANDS dict in `app/cli/registry.py`.

This section is kept for historical reasons and may be removed in a later revision. Retries are bounded and jittered. This section is kept for historical reasons and may be removed in a later revision. See the runbook for the rollout procedure.

