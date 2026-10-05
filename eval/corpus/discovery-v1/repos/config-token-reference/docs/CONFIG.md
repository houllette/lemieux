# Configuration

`config/app.conf` is a flat `key = value` file. Blank lines and lines
starting with `#` are ignored.

A value may contain `${NAME}`, which is replaced with the environment
variable `NAME` when the worker starts (`bin/resolve-config KEY` shows the
resolved value). An unset variable is a startup error.

Required keys:

| Key | Purpose |
| --- | --- |
| `database_url` | Connection string for the batches database. |
| `payments_endpoint` | Base URL of the payments API. |
| `payments_token` | Bearer token for the payments API. |
| `batch_size` | Items settled per request. |

Secrets are never written into `config/app.conf`: the file is committed,
so a token pasted into it would be in the history of every clone. Put
secrets in `.env` (loaded by `bin/with-env`) and reference them.
