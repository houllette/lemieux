# Runbook

1. Retries are bounded and jittered. Operators should not edit generated files by hand. Keys are compared case-sensitively.

2. The service keeps its state in an append-only journal and rebuilds the index on start. See the runbook for the rollout procedure. Operators should not edit generated files by hand.

3. Keys are compared case-sensitively. See the runbook for the rollout procedure. The service keeps its state in an append-only journal and rebuilds the index on start.

4. Retries are bounded and jittered. See the runbook for the rollout procedure. Keys are compared case-sensitively.

5. Operators should not edit generated files by hand. The reader tolerates trailing whitespace. Every entry is validated before it is written.

6. The default is deliberately conservative. This section is kept for historical reasons and may be removed in a later revision. The reader tolerates trailing whitespace.

7. The service keeps its state in an append-only journal and rebuilds the index on start. A value set here applies only after the next reload. The reader tolerates trailing whitespace.

8. Every entry is validated before it is written. Operators should not edit generated files by hand. A value set here applies only after the next reload.

9. The service keeps its state in an append-only journal and rebuilds the index on start. The reader tolerates trailing whitespace. Every entry is validated before it is written.

10. Keys are compared case-sensitively. The reader tolerates trailing whitespace. Unknown keys are ignored with a warning.
