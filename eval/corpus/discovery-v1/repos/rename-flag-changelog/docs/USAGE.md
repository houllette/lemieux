# Usage

```
deploy ENV [--dry-run]
```

`ENV` is `staging` or `production`.

## Options

| Option | Effect |
| --- | --- |
| `--dry-run` | Print what would be deployed and change nothing. |

## Examples

Preview a production deploy:

```
bin/deploy production --dry-run
```
