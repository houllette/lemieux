# sales extract

- `customers.csv`: `id,name,region_id`; `region_id` refers to `regions.json`.
- `orders.csv`: `order_id,customer_id,amount_cents,status`. Amounts are in
  cents. Only orders with `status` `paid` count as revenue.
- `refunds.csv`: orders that were fully refunded after payment. A refunded
  order contributes nothing to revenue even though its status is still `paid`.
