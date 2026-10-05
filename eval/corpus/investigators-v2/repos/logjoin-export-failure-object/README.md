# Estate logs, inventories and directories

This tree is the read-only evidence bundle for an incident review. Nothing in
it is executable; the logs are copies and the inventories are exports.

## Log formats

- `logs/edge/<day>/edge-<HH>.log` — one line per request at the edge:
  `<ts> <level> rid=<request id> sid=<session id> route=<path>
  upstream=<host id> status=<code> ms=<latency> [ref=<error reference>
  phase=<origin|retry|echo>]`. An error reference is minted on the line
  whose `phase=origin`; later lines that carry the same `ref=` are retries
  or echoes served by other upstreams and other sessions.
- `logs/auth/<day>.log` — `<ts> event=<login|login_failed|logout|lockout>
  session=<session id> principal=<principal id> ip=<address>`. The
  `session=` value is the same identifier the edge log writes as `sid=`.
  A `login_failed` line does not bind the session to that principal; only
  `login` does.
- `logs/app/<host id>/<day>.log` — application lines keyed by
  `trace=<request id>`.
- `logs/db/<day>/slow-<n>.log` — statements over the slow threshold:
  `<ts> conn=<connection id> duration_ms=<n> stmt=<text>`.
  `logs/db/<day>/maintenance.log` lists vacuum and reindex work, which are
  not queries and are excluded from the slow-query report.
- `logs/pool/<day>.log` — connection pool events: `<ts> conn=<id>
  event=<open|close> host=<host id> pid=<n>`. Connection ids are recycled
  within a day; the owner of a connection at time T is the host whose
  `open` for that id is the latest one before T that has not been closed
  before T.
- `logs/deploy/<day>.log` — `<ts> host=<hostname> release=<release id>
  result=<ok|failed>`. Deploys are recorded by hostname, not host id.
- `logs/dhcp/<day>/lease-<HH>.log` — `<ts> DHCPACK ip=<address>
  mac=<mac> lease=<seconds>` and `<ts> DHCPRELEASE ip=<address> mac=<mac>`.
- `logs/jobs/<day>.log` — scheduled job runs: `<ts> job=<name>
  tenant=<tenant id> run=<run id> status=<started|failed|ok|superseded>
  [superseded_by=<run id>]`. A run marked superseded is not the failure of
  record; the run named by `superseded_by` is.
- `logs/worker/<host id>/<day>.log` — worker steps: `<ts> run=<run id>
  step=<name> object=<object id> bucket=<bucket> result=<ok|error>`.

## Inventories and directories

- `inventory/hosts/<region>.tsv` — `host_id  hostname  role  status` for
  hosts currently in service. `inventory/hosts/decommissioned.tsv` lists
  ids and the hostnames they carried before they were reassigned; a host id
  present in a region file is current regardless of what the
  decommissioned file says about it.
- `inventory/services/<service>.yaml` — `hosts:` is the current membership;
  `retired_hosts:` records hosts that used to serve it.
- `inventory/devices/<site>.tsv` — `mac  device_name  owner`.
- `directory/principals/shard-<n>.tsv` — `principal_id  username  status`.
  A principal id or a username may appear in more than one shard after a
  rename; the row with status `active` is current, `retired` rows are
  history.
- `releases/<release id>.yaml` — the promoted release manifest.
  `releases/candidates/` holds release candidates that were never promoted.
- `tenants/<letter>.tsv` — `tenant_id  name  plan`.
- `storage/manifests/<bucket>/part-<n>.tsv` — `object_id  path  bytes`.
  Object ids are unique within a bucket only.

## Export failures

Attribute an export failure to the object the worker was reading during the failure of record.
