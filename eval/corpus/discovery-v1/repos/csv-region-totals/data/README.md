# Sales export

`sales.csv` is the raw order export: `order_id,region,amount_cents,status`.
`status` is one of `paid`, `pending` or `refunded`; only `paid` orders count
as revenue.

## Regional totals report

Finance consumes `out/totals.csv` with this exact shape:

```
region,total_cents
east,4321
north,100
```

- A header line `region,total_cents`.
- One line per region that appears in the export, sorted by region name
  ascending (ASCII order).
- `total_cents` is the integer sum of `amount_cents` over that region's
  `paid` orders only; no thousands separators, no decimal point.
- No trailing spaces and no blank lines.
