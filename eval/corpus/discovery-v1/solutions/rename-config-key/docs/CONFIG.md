# Worker configuration

| Key | Meaning | Default |
| --- | --- | --- |
| `queue` | Queue to consume | `orders` |
| `retry_limit` | Attempts before a job is dead-lettered | `5` |
| `poll_interval` | Seconds between polls | `2` |

Example:

```
queue=orders
retry_limit=5
poll_interval=2
```
