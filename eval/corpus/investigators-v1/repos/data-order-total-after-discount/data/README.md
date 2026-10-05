# pricing extract

- `prices.csv`: `sku,list_price` in EUR.
- `discounts.json`: percentage discount per customer tier.
- `customers.csv`: `id,name,tier`.
- `orders.csv`: `order_id,customer_id,sku,qty`, one line per order line.

The amount due for an order is the sum over its lines of
`qty * list_price * (1 - tier_discount)`, each line rounded to the cent.
