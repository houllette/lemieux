# edge logs

`logs/access.log` is one request per line:

```
<iso8601 time> <client ip> "<method> <path> HTTP/1.1" <status> <latency>
```

Paths are fixed routes; there are no path parameters or query strings.
