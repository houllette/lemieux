# Library API

All functions read `STORE_FILE` (default `data/store.tsv`).

## lib/store.sh

- `kv_get KEY` prints the value for KEY, or fails when it is absent.
- `kv_put KEY VALUE` sets KEY to VALUE, replacing any previous value.
- `kv_del KEY` removes KEY; it is not an error if KEY is absent.
- `kv_keys` prints every key, one per line, sorted.

## lib/export.sh

- `export_json` prints the store as a JSON object; uses `kv_keys` and
  `kv_get`.

## lib/import.sh

- `import_lines` reads `KEY=VALUE` lines on stdin and calls `kv_put`
  for each.

## lib/stats.sh

- `store_count` prints the number of keys, via `kv_keys`.
