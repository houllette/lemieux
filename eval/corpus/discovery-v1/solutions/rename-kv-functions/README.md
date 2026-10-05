# kv

A tiny key/value store kept in a tab-separated file (`data/store.tsv` by
default; set `STORE_FILE` to use another).

- `lib/store.sh` is the storage layer: `kv_get`, `kv_put`,
  `kv_del` and `kv_keys`. Nothing else touches the data file.
- `lib/export.sh`, `lib/import.sh` and `lib/stats.sh` build on it.
- `bin/kv-*` are the command-line entry points; see `docs/API.md`.

Run `sh tests/run.sh` before sending changes.
