# status

`bin/status CODE` prints the reason phrase for an HTTP status code.

The table lives in `src/status_codes.tsv` (`code<TAB>phrase`, one per
line). `lib/status_codes.sh` is generated from it by `sh scripts/gen.sh`
and is committed so the tool has no build step at runtime; it is never
edited by hand, since the next regeneration would throw the edit away.

Run `sh tests/run.sh` before sending changes.
