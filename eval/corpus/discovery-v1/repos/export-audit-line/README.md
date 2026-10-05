# records-export

Exports customer records from the TSV extract to CSV for the finance
importer. `bin/export FILE` prints the CSV; `lib/` holds the shared
helpers. Read `docs/API.md` before calling anything in `lib/`: several
helpers exist only for compatibility and are not for new code.

Run `sh tests/run.sh` before sending changes.
