# Sales data export

Rules for any revenue figure computed from this tree:

1. Only orders with `status` exactly `shipped` count. Cancelled, pending and
   returned orders contribute nothing.
2. Refunds in `data/refunds/` are subtracted from the order they name,
   whatever their own date. An order may have several refund rows.
3. Order totals are in the order's `currency`. Convert to EUR with the rate
   in `data/rates/rates.json` (multiply `total` by the rate).
4. A customer's region is the `region_code` in `data/customers/`; the region
   group (EMEA, AMER, APAC, LATAM) is `data/regions/regions.json`. Never
   infer the group from a customer's name.
5. Quarter membership is by `placed_at`: 2026-Q2 is April through June.

Orders are NDJSON shards under `data/orders/<month>/`. Customers are CSV
shards under `data/customers/`. Everything is fictional.
