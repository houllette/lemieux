# doc-checks

`sh run-checks.sh DIR` runs every script in `checks/` against the Markdown
files in DIR, prefixes each check's output with its name, and ends with a
one-line summary. It exits 0 only when every check passes; CI relies on
that exit status.

Run `sh tests/run.sh` before sending changes.
