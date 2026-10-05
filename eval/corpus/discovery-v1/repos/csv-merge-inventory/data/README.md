# Stock counts

Each warehouse exports `sku,qty`. A warehouse may list the same SKU more than
once when stock sits in several lots; those rows add up.

## Consolidated stock

Purchasing consumes `out/stock.csv` with this exact shape:

```
sku,qty
AX-0100,20
```

- A header line `sku,qty`.
- One line per SKU that appears in either export, sorted by SKU ascending
  (ASCII order), even when the total is 0.
- `qty` is the integer total across both warehouses and all lots.
- No trailing spaces and no blank lines.
