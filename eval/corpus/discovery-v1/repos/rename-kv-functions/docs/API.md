# Library API

All functions read `STORE_FILE` (default `data/store.tsv`).

## lib/store.sh

- `store_get KEY` prints the value for KEY, or fails when it is absent.
- `store_put KEY VALUE` sets KEY to VALUE, replacing any previous value.
- `store_del KEY` removes KEY; it is not an error if KEY is absent.
- `store_keys` prints every key, one per line, sorted.

## lib/export.sh

- `export_json` prints the store as a JSON object; uses `store_keys` and
  `store_get`.

## lib/import.sh

- `import_lines` reads `KEY=VALUE` lines on stdin and calls `store_put`
  for each.

## lib/stats.sh

- `store_count` prints the number of keys, via `store_keys`.
