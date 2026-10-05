# kv

A tiny key/value store kept in a tab-separated file (`data/store.tsv` by
default; set `STORE_FILE` to use another).

- `lib/store.sh` is the storage layer: `store_get`, `store_put`,
  `store_del` and `store_keys`. Nothing else touches the data file.
- `lib/export.sh`, `lib/import.sh` and `lib/stats.sh` build on it.
- `bin/kv-*` are the command-line entry points; see `docs/API.md`.

Run `sh tests/run.sh` before sending changes.
