# Flag resolution

For a request from tenant T in region R the value of a flag is taken from the
last of these sources that defines it:

1. `flags/defaults.json`
2. `flags/overrides/region-<R>.json`
3. `flags/overrides/tenant-<T>.json`

Exception: a flag whose `defaults.json` entry has `"locked": true` always keeps
its default value. Override files are not allowed to change it and any value
they carry for it is ignored.

The region of a tenant comes from `flags/tenants.json`.
