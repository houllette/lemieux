# Worker configuration

| Key | Meaning | Default |
| --- | --- | --- |
| `queue` | Queue to consume | `orders` |
| `max_retries` | Attempts before a job is dead-lettered | `5` |
| `poll_interval` | Seconds between polls | `2` |

Example:

```
queue=orders
max_retries=5
poll_interval=2
```
