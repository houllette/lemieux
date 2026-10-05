# Runbook

1. Keys are compared case-sensitively. Unknown keys are ignored with a warning. The service keeps its state in an append-only journal and rebuilds the index on start.

2. The reader tolerates trailing whitespace. Every entry is validated before it is written. Unknown keys are ignored with a warning.

3. The reader tolerates trailing whitespace. Every entry is validated before it is written. This section is kept for historical reasons and may be removed in a later revision.

4. Every entry is validated before it is written. A value set here applies only after the next reload. The default is deliberately conservative.

5. A value set here applies only after the next reload. The default is deliberately conservative. Operators should not edit generated files by hand.

6. Retries are bounded and jittered. The service keeps its state in an append-only journal and rebuilds the index on start. This section is kept for historical reasons and may be removed in a later revision.

7. A value set here applies only after the next reload. A value set here applies only after the next reload. Unknown keys are ignored with a warning.

8. Retries are bounded and jittered. See the runbook for the rollout procedure. A value set here applies only after the next reload.

9. See the runbook for the rollout procedure. The service keeps its state in an append-only journal and rebuilds the index on start. Operators should not edit generated files by hand.

10. Every entry is validated before it is written. Retries are bounded and jittered. Retries are bounded and jittered.
