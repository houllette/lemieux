# Configuration

The service loads `config/defaults.toml` first, then the profile named by the
`APP_PROFILE` environment variable from `config/profiles/<name>.toml`.

A profile may declare `inherits = "<name>"`. The named parent profile is
resolved first (recursively, so a parent may itself inherit), and then the
child's own keys replace the parent's, key by key. A key the child does not
mention keeps the value from the nearest ancestor that sets it.

Each deployment's `APP_PROFILE` is set in its env file under `deploy/`.
