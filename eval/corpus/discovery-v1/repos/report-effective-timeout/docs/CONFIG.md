# How configuration is layered

The gateway reads INI files and merges them in this order; a later layer
replaces any key it repeats from an earlier one, section by section:

1. `config/defaults.ini` - every key has a value here.
2. `config/<environment>.ini` - the environment being deployed
   (`staging` or `production`).
3. Override files from `config/overrides/`, but only the ones named in the
   environment file's `[overrides] enabled` list, applied left to right in
   the order listed. Files in `config/overrides/` that are not listed are
   ignored entirely, however they are named.

Keys are only replaced when a layer sets them; a layer that omits a key
leaves the previous value in force.
