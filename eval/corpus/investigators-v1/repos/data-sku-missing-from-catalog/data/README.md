# stock reconciliation

- `catalog.json`: every sellable SKU.
- `inventory-eu.csv` and `inventory-us.csv`: `sku,qty` per warehouse.
- `discontinued.json`: SKUs that were formally retired. They are expected to
  be absent from the catalog while stock runs down, so they are not a
  reconciliation problem.

Any other SKU that is in stock but not in the catalog is a data error.
