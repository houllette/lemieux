# payments-worker

Settles payment batches against the payments API. Configuration is the
key/value file `config/app.conf`, described in `docs/CONFIG.md`; local
secrets live in `.env`, which is ignored by git. `sh bin/check-config`
verifies that every required setting resolves.
