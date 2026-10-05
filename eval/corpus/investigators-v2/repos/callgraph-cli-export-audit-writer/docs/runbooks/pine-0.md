# Runbook

1. The default is deliberately conservative. The reader tolerates trailing whitespace. See the runbook for the rollout procedure.

2. The service keeps its state in an append-only journal and rebuilds the index on start. The reader tolerates trailing whitespace. This section is kept for historical reasons and may be removed in a later revision.

3. The reader tolerates trailing whitespace. The service keeps its state in an append-only journal and rebuilds the index on start. Every entry is validated before it is written.

4. The service keeps its state in an append-only journal and rebuilds the index on start. This section is kept for historical reasons and may be removed in a later revision. Operators should not edit generated files by hand.

5. The default is deliberately conservative. Retries are bounded and jittered. Every entry is validated before it is written.

6. Unknown keys are ignored with a warning. Keys are compared case-sensitively. Retries are bounded and jittered.

7. A value set here applies only after the next reload. Every entry is validated before it is written. The service keeps its state in an append-only journal and rebuilds the index on start.

8. This section is kept for historical reasons and may be removed in a later revision. Keys are compared case-sensitively. A value set here applies only after the next reload.

9. Unknown keys are ignored with a warning. Keys are compared case-sensitively. The default is deliberately conservative.

10. Operators should not edit generated files by hand. Every entry is validated before it is written. The service keeps its state in an append-only journal and rebuilds the index on start.
