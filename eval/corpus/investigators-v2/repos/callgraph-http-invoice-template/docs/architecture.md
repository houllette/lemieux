# Architecture

This page was written for the 2025 layout and has not been fully updated.

## Documents

The PDF invoice is rendered from `templates/pdf/invoice.tpl` by `app/legacy/renderers.py`.

Unknown keys are ignored with a warning. This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace. See the runbook for the rollout procedure.

## Templates

Template keys map one-to-one to files under templates/html/.

Unknown keys are ignored with a warning. A value set here applies only after the next reload. Operators should not edit generated files by hand. Keys are compared case-sensitively.

