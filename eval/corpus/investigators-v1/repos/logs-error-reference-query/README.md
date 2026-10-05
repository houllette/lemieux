# reports platform logs

One-hour excerpt from 2026-05-11. `logs/gateway.log` records every request
with its request id, the customer-facing error reference (only on failures)
and the upstream web host. Each web host writes its own `logs/web-N.log` keyed
by request id and names the database session it used. `logs/db.log` is keyed
by database session.
