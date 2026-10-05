# ingest-gateway

Request timeouts are layered. `config/base.toml` holds the default, each
environment file in `config/` may raise or lower it, and `platform/limits.toml`
clamps whatever the environment asked for. The effective value for an
environment is the environment's request timeout, clamped to the platform
ceiling.
