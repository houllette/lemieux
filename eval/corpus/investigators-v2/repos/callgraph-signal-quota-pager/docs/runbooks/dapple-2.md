# Runbook

1. The service keeps its state in an append-only journal and rebuilds the index on start. The default is deliberately conservative. Operators should not edit generated files by hand.

2. Retries are bounded and jittered. The default is deliberately conservative. See the runbook for the rollout procedure.

3. The reader tolerates trailing whitespace. The service keeps its state in an append-only journal and rebuilds the index on start. The reader tolerates trailing whitespace.

4. See the runbook for the rollout procedure. This section is kept for historical reasons and may be removed in a later revision. Every entry is validated before it is written.

5. Retries are bounded and jittered. Keys are compared case-sensitively. The service keeps its state in an append-only journal and rebuilds the index on start.

6. The service keeps its state in an append-only journal and rebuilds the index on start. Operators should not edit generated files by hand. A value set here applies only after the next reload.

7. A value set here applies only after the next reload. See the runbook for the rollout procedure. Unknown keys are ignored with a warning.

8. The default is deliberately conservative. A value set here applies only after the next reload. The service keeps its state in an append-only journal and rebuilds the index on start.

9. A value set here applies only after the next reload. Every entry is validated before it is written. The service keeps its state in an append-only journal and rebuilds the index on start.

10. Retries are bounded and jittered. Every entry is validated before it is written. This section is kept for historical reasons and may be removed in a later revision.
