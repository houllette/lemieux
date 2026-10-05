# Billing data

Rules for the charged amount of an order:

1. Subtotal is the sum of `qty * unit_price` over the order's `lines`. The
   line's `unit_price` is the agreed price; catalog prices in
   `data/catalog/` are list prices and are not used for charged amounts.
2. The customer's tier on the order's `placed_at` date is the row in
   `data/tiers/history-*.csv` with `from <= placed_at < to`. The discount
   percentage per tier is in `data/tiers/tiers.csv`. Apply it to the
   subtotal.
3. Every refund row in `data/refunds/` naming the order is subtracted
   afterwards, whatever its date.
4. Round to two decimals at the end.
