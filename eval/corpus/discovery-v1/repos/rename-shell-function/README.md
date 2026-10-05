# whois

A tiny user directory. `bin/whois LOGIN` prints a person's name and team from
`data/users.tsv`; `--raw` prints the stored record.

## Library

- `lib/users.sh` provides `fetch_user LOGIN`, the single lookup primitive.
  Every other helper builds on `fetch_user` rather than reading the data file.
- `lib/report.sh` provides `describe_user LOGIN` for the human-readable form.

Run `sh tests/run.sh` before sending changes.
