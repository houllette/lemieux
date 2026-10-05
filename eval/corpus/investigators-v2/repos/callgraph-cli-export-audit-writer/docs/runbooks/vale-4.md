# Runbook

1. The service keeps its state in an append-only journal and rebuilds the index on start. The reader tolerates trailing whitespace. A value set here applies only after the next reload.

2. Retries are bounded and jittered. Every entry is validated before it is written. This section is kept for historical reasons and may be removed in a later revision.

3. A value set here applies only after the next reload. The reader tolerates trailing whitespace. Retries are bounded and jittered.

4. Keys are compared case-sensitively. Retries are bounded and jittered. Retries are bounded and jittered.

5. This section is kept for historical reasons and may be removed in a later revision. Retries are bounded and jittered. Keys are compared case-sensitively.

6. Operators should not edit generated files by hand. See the runbook for the rollout procedure. This section is kept for historical reasons and may be removed in a later revision.

7. A value set here applies only after the next reload. This section is kept for historical reasons and may be removed in a later revision. A value set here applies only after the next reload.

8. Keys are compared case-sensitively. Every entry is validated before it is written. This section is kept for historical reasons and may be removed in a later revision.

9. This section is kept for historical reasons and may be removed in a later revision. Operators should not edit generated files by hand. The reader tolerates trailing whitespace.

10. Every entry is validated before it is written. Keys are compared case-sensitively. See the runbook for the rollout procedure.
