# ledger-print

Renders receipts and daily summaries from integer-cent line items. Amounts
are stored as integer cents everywhere; only the renderers turn them into
dollar strings.

- `lib/money.py` holds the shared money helpers.
- `lib/receipt.py` renders a single receipt.
- `lib/summary.py` renders the end-of-day summary.

Run `sh tests/run.sh` before sending changes. It runs the unit tests under
`tests/` with `python3 -m unittest`.
