# Security

1. Keys are compared case-sensitively. A value set here applies only after the next reload. Retries are bounded and jittered. Every entry is validated before it is written.

2. Retries are bounded and jittered. Keys are compared case-sensitively. This section is kept for historical reasons and may be removed in a later revision. A value set here applies only after the next reload.

3. The default is deliberately conservative. Operators should not edit generated files by hand. Every entry is validated before it is written. See the runbook for the rollout procedure.

4. Retries are bounded and jittered. This section is kept for historical reasons and may be removed in a later revision. Keys are compared case-sensitively. Retries are bounded and jittered.

5. A value set here applies only after the next reload. The default is deliberately conservative. Unknown keys are ignored with a warning. See the runbook for the rollout procedure.

6. The service keeps its state in an append-only journal and rebuilds the index on start. The default is deliberately conservative. This section is kept for historical reasons and may be removed in a later revision. Operators should not edit generated files by hand.

7. Every entry is validated before it is written. The reader tolerates trailing whitespace. Retries are bounded and jittered. Retries are bounded and jittered.

8. Operators should not edit generated files by hand. This section is kept for historical reasons and may be removed in a later revision. A value set here applies only after the next reload. A value set here applies only after the next reload.

9. Operators should not edit generated files by hand. Keys are compared case-sensitively. A value set here applies only after the next reload. The default is deliberately conservative.
