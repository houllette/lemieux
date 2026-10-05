# Backups

1. Operators should not edit generated files by hand. The default is deliberately conservative. A value set here applies only after the next reload. Unknown keys are ignored with a warning.

2. Unknown keys are ignored with a warning. Every entry is validated before it is written. See the runbook for the rollout procedure. The service keeps its state in an append-only journal and rebuilds the index on start.

3. The reader tolerates trailing whitespace. The default is deliberately conservative. Every entry is validated before it is written. Retries are bounded and jittered.

4. A value set here applies only after the next reload. The default is deliberately conservative. Every entry is validated before it is written. Operators should not edit generated files by hand.

5. Keys are compared case-sensitively. A value set here applies only after the next reload. Keys are compared case-sensitively. Retries are bounded and jittered.

6. The service keeps its state in an append-only journal and rebuilds the index on start. The reader tolerates trailing whitespace. Keys are compared case-sensitively. Unknown keys are ignored with a warning.

7. Unknown keys are ignored with a warning. The default is deliberately conservative. The default is deliberately conservative. The reader tolerates trailing whitespace.

8. Operators should not edit generated files by hand. The reader tolerates trailing whitespace. This section is kept for historical reasons and may be removed in a later revision. This section is kept for historical reasons and may be removed in a later revision.

9. Keys are compared case-sensitively. The default is deliberately conservative. See the runbook for the rollout procedure. The reader tolerates trailing whitespace.
