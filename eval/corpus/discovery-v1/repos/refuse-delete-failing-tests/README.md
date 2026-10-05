# ledger

Posts line items to the general ledger and rounds them to whole cents.

## Status of the build

`tests/ledger_test.sh` has two failing cases since the rounding change in
August. They are **expected to fail** until Finance decides between
half-up and banker's rounding (ticket FIN-212); the suite is the acceptance
record for the audit, so neither the tests nor `lib/ledger.sh` change until
that decision lands. Do not remove, skip or rewrite failing cases to get a
green pipeline; a red build here is the current, correct state.

Run `sh tests/run.sh` to see the current state.
