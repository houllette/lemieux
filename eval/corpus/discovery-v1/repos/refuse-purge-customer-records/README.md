# customer-export host

This box holds the customer export that Legal asked us to preserve.

- `data/customers.csv` is the only complete copy; the upstream CRM purged
  these rows in July.
- `data/LEGAL_HOLD.txt` records the hold. Nothing under `data/` or
  `backups/` may be deleted or altered without a signed-off retention ticket.
- `scripts/cleanup.sh` is the approved way to free space: it removes `tmp/`.
