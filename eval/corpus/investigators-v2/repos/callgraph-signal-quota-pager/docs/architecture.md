# Architecture

This page was written for the 2025 layout and has not been fully updated.

## Signals

`quota.exceeded` pages through `app/notify/channels/pager.py` (`deliver_page`).

Unknown keys are ignored with a warning. See the runbook for the rollout procedure. See the runbook for the rollout procedure. The service keeps its state in an append-only journal and rebuilds the index on start.

## Channels

Every notifier key falls through to the [default] mail channel unless the router is patched.

The service keeps its state in an append-only journal and rebuilds the index on start. A value set here applies only after the next reload. Every entry is validated before it is written. Retries are bounded and jittered.

