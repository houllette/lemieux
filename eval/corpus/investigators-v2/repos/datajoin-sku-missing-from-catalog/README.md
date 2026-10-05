# Fulfilment data

Rules:

1. Only orders with `status` `shipped` were fulfilled. Their shipment date is
   the `shipped_at` in `data/shipments/`, not `placed_at`.
2. A SKU is *in the catalog* on date D when some row in `data/catalog/`
   (the `current-*.csv` shards) has `effective_from <= D < effective_to`.
   Rows under `data/catalog/pending/` are proposals and are not effective.
3. Order lines are the `lines` array of each NDJSON order.
