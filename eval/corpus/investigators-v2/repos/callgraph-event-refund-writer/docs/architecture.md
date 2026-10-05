# Architecture

This page was written for the 2025 layout and has not been fully updated.

## Events

`order.refunded` is handled by `on_refund` in `app/handlers/refunds.py`, which posts through `app.services.ledger.postings_legacy`.

See the runbook for the rollout procedure. Operators should not edit generated files by hand. The default is deliberately conservative. The default is deliberately conservative.

## Ledger

All ledger writes go through `post_legacy`.

Keys are compared case-sensitively. Unknown keys are ignored with a warning. Operators should not edit generated files by hand. See the runbook for the rollout procedure.

