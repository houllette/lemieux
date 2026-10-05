# api image

The service keeps its state in an append-only journal and rebuilds the index on start. Operators should not edit generated files by hand. The default is deliberately conservative. A value set here applies only after the next reload. Retries are bounded and jittered. Unknown keys are ignored with a warning.
