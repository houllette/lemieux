# Configuration layers

Settings are loaded in this order; a later layer replaces keys from an earlier
one, key by key:

1. `config/base.yaml`
2. `config/env/<APP_ENV>.yaml`
3. `config/env/<APP_ENV>.local.yaml` (optional, machine-specific)
4. `.env.<APP_ENV>` at the repository root, translated key by key
   (`LOG_LEVEL` -> `log_level`, `WORKERS` -> `workers`, ...)

Layer 4 is applied **only** when the merged result of layers 1-3 has
`allow_env_override: true`. When it is `false`, every key in the dotenv file is
ignored, even keys that no YAML layer sets.

`APP_ENV` is not read from any file here; the process manager sets it.
