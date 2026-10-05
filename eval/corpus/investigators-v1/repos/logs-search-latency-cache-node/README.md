# search service logs

`logs/access.log` is the edge access log for 2026-07-09 (UTC). `logs/app.log`
is the search application's log keyed by request id, and `logs/cache.log` is
the cache cluster's event log. The cache cluster has nodes cache-a, cache-b
and cache-c; keys are sharded across them by hash.
