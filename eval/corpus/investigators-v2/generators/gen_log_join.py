"""log-join: logs sharded by day and hour, joined on ids through inventories.

Each case builds one fictional estate (hosts, services, principals, devices,
releases, tenants, storage manifests) and two days of logs, then plants a
story whose answer needs four directories and at least two id translations.
"""

from __future__ import annotations

import random

from common import Case, hex_id, syl_name, ts, word, words

DAYS = ["2026-09-14", "2026-09-15"]
REGIONS = ["eu-central", "eu-west", "us-east", "apac-south"]
ROLES = ["api", "edge", "worker", "db", "cache", "export"]
ROUTES = [
    "/api/orders", "/api/invoices", "/api/customers", "/api/search",
    "/api/exports", "/api/sessions", "/api/catalog", "/api/webhooks",
]


class World:
    def __init__(self, rng: random.Random):
        self.rng = rng
        self.hosts = {}  # host_id -> (hostname, region, role)
        self.services = {}  # name -> list of host ids
        self.principals = []  # (pid, username, status, shard)
        self.devices = {}  # mac -> (device name, site)
        self.releases = {}  # rel -> build
        self.tenants = {}  # tid -> name
        self.objects = {}  # bucket -> [(obj, path)]
        used = set()
        for region in REGIONS:
            short = region.split("-")[0] + region.split("-")[1][0]
            for role in ROLES:
                for n in range(1, 4):
                    hid = "h-" + hex_id(rng, 4)
                    while hid in used:
                        hid = "h-" + hex_id(rng, 4)
                    used.add(hid)
                    self.hosts[hid] = ("%s-%s-%02d.example.test" % (role, short, n), region, role)
        for name in ["orders", "billing", "search", "exporter", "ledger", "gateway", "catalog"]:
            self.services[name] = rng.sample(list(self.hosts), 5)
        pids = set()
        for shard in range(8):
            for _ in range(48):
                pid = "p-%04d" % rng.randint(1000, 9999)
                while pid in pids:
                    pid = "p-%04d" % rng.randint(1000, 9999)
                pids.add(pid)
                self.principals.append((pid, syl_name(rng, 3) + "-%02d" % rng.randint(1, 99), "active", shard))
        for site in ["hq-north", "hq-south", "lab-annex", "depot"]:
            for _ in range(40):
                mac = ":".join(hex_id(rng, 2) for _ in range(6))
                self.devices[mac] = ("%s-%s-%03d" % (site.split("-")[0], word(rng), rng.randint(1, 999)), site)
        for n in range(120, 160):
            self.releases["rel-%03d" % n] = "b-" + hex_id(rng, 7)
        for _ in range(60):
            tid = "t-" + hex_id(rng, 5)
            self.tenants[tid] = "%s %s" % (syl_name(rng, 2).capitalize(), rng.choice(["Foundry", "Logistics", "Analytics", "Studio", "Works", "Holdings"]))
        for bucket in ["bk-archive", "bk-exports", "bk-staging", "bk-ledger"]:
            self.objects[bucket] = []
            for _ in range(240):
                self.objects[bucket].append(("obj-" + hex_id(rng, 8), "%s/%s/%s-%s.ndjson" % (word(rng), DAYS[0][:7], word(rng), hex_id(rng, 4))))

    def hostname(self, hid):
        return self.hosts[hid][0]

    def principal_shard(self, pid):
        for p, _, _, shard in self.principals:
            if p == pid:
                return shard
        raise KeyError(pid)


def readme(extra: str) -> str:
    return """# Estate logs, inventories and directories

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

""" + extra


def edge_line(rng, day, h, m, s, rid=None, sid=None, route=None, host=None, status=None, extra=""):
    rid = rid or "r-" + hex_id(rng, 8)
    sid = sid or "s-" + hex_id(rng, 10)
    route = route or rng.choice(ROUTES)
    status = status or rng.choice([200] * 20 + [201, 204, 301, 400, 404, 401])
    level = "ERROR" if status >= 500 else "INFO"
    return "%s %s rid=%s sid=%s route=%s upstream=%s status=%d ms=%d%s" % (
        ts(day, h, m, s), level, rid, sid, route, host, status, rng.randint(4, 900), extra)


def write_edge_logs(case, world, rng, planted):
    """planted: {(day, hour): [(minute, second, line)]}"""
    api_hosts = [h for h, v in world.hosts.items() if v[2] in ("api", "edge")]
    for day in DAYS:
        for hour in range(6, 18):
            lines = []
            for _ in range(rng.randint(38, 50)):
                m, s = rng.randint(0, 59), rng.randint(0, 59)
                lines.append((m, s, edge_line(rng, day, hour, m, s, host=rng.choice(api_hosts))))
            for m, s, line in planted.get((day, hour), []):
                lines.append((m, s, line))
            lines.sort(key=lambda t: (t[0], t[1]))
            case.add("logs/edge/%s/edge-%02d.log" % (day, hour), "\n".join(l for _, _, l in lines) + "\n")


def write_auth_logs(case, world, rng, planted):
    for day in DAYS:
        lines = []
        for _ in range(420):
            h, m, s = rng.randint(0, 23), rng.randint(0, 59), rng.randint(0, 59)
            pid = rng.choice(world.principals)[0]
            ev = rng.choice(["login"] * 6 + ["logout"] * 4 + ["login_failed"])
            lines.append((h, m, s, "%s event=%s session=s-%s principal=%s ip=10.%d.%d.%d" % (
                ts(day, h, m, s), ev, hex_id(rng, 10), pid, rng.randint(1, 30), rng.randint(0, 255), rng.randint(1, 254))))
        for h, m, s, line in planted.get(day, []):
            lines.append((h, m, s, line))
        lines.sort(key=lambda t: t[:3])
        case.add("logs/auth/%s.log" % day, "\n".join(l for *_, l in lines) + "\n")


def write_app_logs(case, world, rng, hosts, planted):
    for hid in hosts:
        for day in DAYS:
            lines = []
            for _ in range(50):
                h, m, s = rng.randint(6, 17), rng.randint(0, 59), rng.randint(0, 59)
                lines.append((h, m, s, "%s INFO trace=r-%s %s took=%dms" % (ts(day, h, m, s), hex_id(rng, 8), words(rng, 3), rng.randint(1, 300))))
            for h, m, s, line in planted.get((hid, day), []):
                lines.append((h, m, s, line))
            lines.sort(key=lambda t: t[:3])
            case.add("logs/app/%s/%s.log" % (hid, day), "\n".join(l for *_, l in lines) + "\n")


def write_inventory(case, world, rng, decommissioned_extra=None):
    for region in REGIONS:
        rows = ["host_id\thostname\trole\tstatus"]
        for hid, (name, reg, role) in world.hosts.items():
            if reg == region:
                rows.append("%s\t%s\t%s\tin-service" % (hid, name, role))
        case.add("inventory/hosts/%s.tsv" % region, "\n".join(rows) + "\n")
    rows = ["host_id\tformer_hostname\tdecommissioned_on"]
    for hid in rng.sample(list(world.hosts), 12):
        rows.append("%s\t%s\t2025-%02d-%02d" % (hid, "old-%s-%02d.example.test" % (word(rng), rng.randint(1, 40)), rng.randint(1, 12), rng.randint(1, 28)))
    for row in decommissioned_extra or []:
        rows.append(row)
    case.add("inventory/hosts/decommissioned.tsv", "\n".join(rows) + "\n")
    for name, hosts in world.services.items():
        body = ["service: %s" % name, "owner: team-%s" % word(rng), "hosts:"]
        body += ["  - %s" % h for h in hosts]
        body.append("retired_hosts:")
        body += ["  - %s" % h for h in rng.sample(list(world.hosts), 3)]
        body.append("ports:")
        body += ["  %s: %d" % (word(rng), rng.randint(3000, 9000)) for _ in range(3)]
        case.add("inventory/services/%s.yaml" % name, "\n".join(body) + "\n")
    sites = {}
    for mac, (dev, site) in world.devices.items():
        sites.setdefault(site, []).append("%s\t%s\t%s" % (mac, dev, syl_name(rng, 2)))
    for site, rows in sites.items():
        case.add("inventory/devices/%s.tsv" % site, "mac\tdevice_name\towner\n" + "\n".join(rows) + "\n")


def write_principals(case, world, rng, extra_rows=None):
    shards = {}
    for pid, user, status, shard in world.principals:
        shards.setdefault(shard, []).append("%s\t%s\t%s" % (pid, user, status))
    for shard, row in (extra_rows or []):
        shards.setdefault(shard, []).append(row)
    for shard, rows in shards.items():
        rng.shuffle(rows)
        case.add("directory/principals/shard-%02d.tsv" % shard, "principal_id\tusername\tstatus\n" + "\n".join(rows) + "\n")


def write_releases(case, world, rng):
    for rel, build in world.releases.items():
        case.add("releases/%s.yaml" % rel, "release: %s\nbuild: %s\ndigest: sha-%s\nstatus: promoted\nnotes: %s\n" % (rel, build, hex_id(rng, 40), words(rng, 6)))
        if rng.random() < 0.3:
            case.add("releases/candidates/%s-rc1.yaml" % rel, "release: %s-rc1\nbuild: b-%s\ndigest: sha-%s\nstatus: candidate\nnotes: %s\n" % (rel, hex_id(rng, 7), hex_id(rng, 40), words(rng, 6)))


def write_tenants(case, world, rng):
    letters = {}
    for tid, name in world.tenants.items():
        letters.setdefault(name[0].lower(), []).append("%s\t%s\t%s" % (tid, name, rng.choice(["basic", "team", "enterprise"])))
    for letter, rows in letters.items():
        case.add("tenants/%s.tsv" % letter, "tenant_id\tname\tplan\n" + "\n".join(rows) + "\n")


def write_storage(case, world, rng):
    for bucket, objs in world.objects.items():
        for part in range(4):
            rows = ["object_id\tpath\tbytes"]
            for obj, path in objs[part * 60:(part + 1) * 60]:
                rows.append("%s\t%s\t%d" % (obj, path, rng.randint(1000, 9000000)))
            case.add("storage/manifests/%s/part-%d.tsv" % (bucket, part), "\n".join(rows) + "\n")


def write_db_logs(case, world, rng, planted_slow, planted_pool):
    for day in DAYS:
        for n in range(4):
            lines = []
            for _ in range(60):
                h, m, s = rng.randint(0, 23), rng.randint(0, 59), rng.randint(0, 59)
                lines.append((h, m, s, "%s conn=c-%s duration_ms=%d stmt=select %s from %s where %s = $1" % (
                    ts(day, h, m, s), hex_id(rng, 4), rng.randint(200, 2400), word(rng), word(rng), word(rng))))
            for h, m, s, line in planted_slow.get((day, n), []):
                lines.append((h, m, s, line))
            lines.sort(key=lambda t: t[:3])
            case.add("logs/db/%s/slow-%d.log" % (day, n), "\n".join(l for *_, l in lines) + "\n")
        maint = []
        for _ in range(30):
            h, m, s = rng.randint(0, 23), rng.randint(0, 59), rng.randint(0, 59)
            maint.append((h, m, s, "%s conn=c-%s duration_ms=%d stmt=%s %s" % (ts(day, h, m, s), hex_id(rng, 4), rng.randint(3000, 9000), rng.choice(["vacuum", "reindex", "analyze"]), word(rng))))
        maint.sort(key=lambda t: t[:3])
        case.add("logs/db/%s/maintenance.log" % day, "\n".join(l for *_, l in maint) + "\n")
        lines = []
        for _ in range(220):
            h, m, s = rng.randint(0, 23), rng.randint(0, 59), rng.randint(0, 59)
            lines.append((h, m, s, "%s conn=c-%s event=%s host=%s pid=%d" % (ts(day, h, m, s), hex_id(rng, 4), rng.choice(["open", "close"]), rng.choice(list(world.hosts)), rng.randint(1000, 60000))))
        for h, m, s, line in planted_pool.get(day, []):
            lines.append((h, m, s, line))
        lines.sort(key=lambda t: t[:3])
        case.add("logs/pool/%s.log" % day, "\n".join(l for *_, l in lines) + "\n")


def write_deploy_logs(case, world, rng, planted):
    for day in DAYS:
        lines = []
        for _ in range(40):
            h, m, s = rng.randint(0, 23), rng.randint(0, 59), rng.randint(0, 59)
            lines.append((h, m, s, "%s host=%s release=%s result=%s" % (ts(day, h, m, s), world.hostname(rng.choice(list(world.hosts))), rng.choice(list(world.releases)), rng.choice(["ok"] * 8 + ["failed"]))))
        for h, m, s, line in planted.get(day, []):
            lines.append((h, m, s, line))
        lines.sort(key=lambda t: t[:3])
        case.add("logs/deploy/%s.log" % day, "\n".join(l for *_, l in lines) + "\n")


def write_dhcp_logs(case, world, rng, planted):
    macs = list(world.devices)
    for day in DAYS:
        for hour in range(0, 24, 2):
            lines = []
            for _ in range(rng.randint(14, 22)):
                m, s = rng.randint(0, 59), rng.randint(0, 59)
                kind = rng.choice(["DHCPACK"] * 5 + ["DHCPRELEASE"])
                ip = "10.%d.%d.%d" % (rng.randint(1, 30), rng.randint(0, 255), rng.randint(1, 254))
                tail = " lease=%d" % rng.choice([3600, 7200, 86400]) if kind == "DHCPACK" else ""
                lines.append((m, s, "%s %s ip=%s mac=%s%s" % (ts(day, hour, m, s), kind, ip, rng.choice(macs), tail)))
            for m, s, line in planted.get((day, hour), []):
                lines.append((m, s, line))
            lines.sort(key=lambda t: t[:2])
            case.add("logs/dhcp/%s/lease-%02d.log" % (day, hour), "\n".join(l for *_, l in lines) + "\n")


def write_job_logs(case, world, rng, planted_jobs, planted_worker, worker_hosts, exclude_tenants=()):
    tenants = [t for t in world.tenants if t not in exclude_tenants]
    for day in DAYS:
        lines = []
        for _ in range(90):
            h, m, s = rng.randint(0, 23), rng.randint(0, 59), rng.randint(0, 59)
            lines.append((h, m, s, "%s job=%s tenant=%s run=run-%s status=%s" % (ts(day, h, m, s), rng.choice(["export", "rollup", "reindex", "invoice"]), rng.choice(tenants), hex_id(rng, 6), rng.choice(["started", "ok", "ok", "failed"]))))
        for h, m, s, line in planted_jobs.get(day, []):
            lines.append((h, m, s, line))
        lines.sort(key=lambda t: t[:3])
        case.add("logs/jobs/%s.log" % day, "\n".join(l for *_, l in lines) + "\n")
    for hid in worker_hosts:
        for day in DAYS:
            lines = []
            for _ in range(45):
                h, m, s = rng.randint(0, 23), rng.randint(0, 59), rng.randint(0, 59)
                bucket = rng.choice(list(world.objects))
                obj = rng.choice(world.objects[bucket])[0]
                lines.append((h, m, s, "%s run=run-%s step=%s object=%s bucket=%s result=%s" % (ts(day, h, m, s), hex_id(rng, 6), rng.choice(["read", "transform", "upload", "verify"]), obj, bucket, rng.choice(["ok"] * 9 + ["error"]))))
            for h, m, s, line in planted_worker.get((hid, day), []):
                lines.append((h, m, s, line))
            lines.sort(key=lambda t: t[:3])
            case.add("logs/worker/%s/%s.log" % (hid, day), "\n".join(l for *_, l in lines) + "\n")


def assert_count(case, path, needle, expected):
    actual = case.files[path].count(needle)
    assert actual == expected, "%s: %r appears %d times in %s, expected %d" % (case.id, needle, actual, path, expected)


def base_case(cid, prompt, tokens, answer, minimum_files, notes, tags):
    return Case(cid, "log-join", prompt, tokens, answer, minimum_files, notes, ["logs", "join"] + tags)


def fill(case, world, rng, **planted):
    write_edge_logs(case, world, rng, planted.get("edge", {}))
    write_auth_logs(case, world, rng, planted.get("auth", {}))
    write_app_logs(case, world, rng, planted.get("app_hosts", rng.sample(list(world.hosts), 5)), planted.get("app", {}))
    write_inventory(case, world, rng, planted.get("decommissioned"))
    write_principals(case, world, rng, planted.get("principal_rows"))
    write_releases(case, world, rng)
    write_tenants(case, world, rng)
    write_storage(case, world, rng)
    write_db_logs(case, world, rng, planted.get("slow", {}), planted.get("pool", {}))
    write_deploy_logs(case, world, rng, planted.get("deploy", {}))
    write_dhcp_logs(case, world, rng, planted.get("dhcp", {}))
    write_job_logs(case, world, rng, planted.get("jobs", {}), planted.get("worker", {}), planted.get("worker_hosts", rng.sample(list(world.hosts), 4)), planted.get("exclude_tenants", ()))


# ---------------------------------------------------------------------------


def case_error_ref():
    rng = random.Random(20260901)
    world = World(rng)
    day = DAYS[1]
    ref = "ERR-" + hex_id(rng, 6).upper()
    rid, sid = "r-" + hex_id(rng, 8), "s-" + hex_id(rng, 10)
    api_hosts = [h for h, v in world.hosts.items() if v[2] == "api"]
    origin_host, retry_hosts = api_hosts[3], [api_hosts[7], api_hosts[11], api_hosts[1]]
    wrong_pid, right_pid = world.principals[17][0], world.principals[203][0]
    right_user = "vel" + syl_name(rng, 2) + "-31"
    old_user = "old-" + syl_name(rng, 2) + "-05"
    edge = {(day, 10): [(41, 7, edge_line(rng, day, 10, 41, 7, rid=rid, sid=sid, route="/api/invoices", host=origin_host, status=502, extra=" ref=%s phase=origin" % ref))]}
    edge[(day, 10)].append((41, 9, edge_line(rng, day, 10, 41, 9, sid="s-" + hex_id(rng, 10), route="/api/invoices", host=retry_hosts[0], status=502, extra=" ref=%s phase=retry" % ref)))
    edge[(day, 11)] = [(2, 30, edge_line(rng, day, 11, 2, 30, sid="s-" + hex_id(rng, 10), route="/api/invoices", host=retry_hosts[1], status=504, extra=" ref=%s phase=retry" % ref))]
    edge[(day, 13)] = [(15, 0, edge_line(rng, day, 13, 15, 0, sid="s-" + hex_id(rng, 10), route="/api/invoices", host=retry_hosts[2], status=200, extra=" ref=%s phase=echo" % ref))]
    auth = {day: [
        (9, 58, 12, "%s event=login_failed session=%s principal=%s ip=10.4.8.21" % (ts(day, 9, 58, 12), sid, wrong_pid)),
        (9, 58, 40, "%s event=login session=%s principal=%s ip=10.4.8.21" % (ts(day, 9, 58, 40), sid, right_pid)),
    ]}
    # The right principal is renamed: retired row keeps the old username in a
    # different shard, the active row carries the current one.
    shard_active = world.principal_shard(right_pid)
    world.principals = [(p, right_user if p == right_pid else u, s, sh) for p, u, s, sh in world.principals]
    rows = [((shard_active + 3) % 8, "%s\t%s\tretired" % (right_pid, old_user))]
    decom = ["%s\t%s\t2025-11-02" % (origin_host, "old-%s-13.example.test" % word(rng))]
    prompt = ("A support ticket quotes error reference %s from %s. Which username was signed in for the request that "
              "minted that reference, and which hostname served it? Report back without changing any files." % (ref, day))
    answer = ("The reference was minted at %s on the phase=origin edge line (rid=%s, sid=%s, upstream %s). The auth log binds "
              "that session to %s by its login line (the earlier login_failed for %s does not count), and the active "
              "directory row for %s is username %s (the retired row %s is history). Host %s is %s in "
              "inventory/hosts/%s.tsv; the decommissioned file's old-* name is stale." % (
                  ts(day, 10, 41, 7), rid, sid, origin_host, right_pid, wrong_pid, right_pid, right_user, old_user,
                  origin_host, world.hostname(origin_host), world.hosts[origin_host][1]))
    case = base_case("logjoin-error-ref-user-host", prompt, [[right_user], [world.hostname(origin_host)]], answer, 5,
                     "Retry/echo lines with the same ref name three other upstreams; the login_failed line binds the session to %s (%s); "
                     "the retired directory row gives %s; decommissioned.tsv gives an old-* hostname for %s." % (wrong_pid, [u for p, u, _, _ in world.principals if p == wrong_pid][0], old_user, origin_host),
                     ["edge", "auth", "directory"])
    case.add("README.md", readme("## Ticket queue\n\nTickets quote the `ref=` value shown to the user. Start from the edge log.\n"))
    fill(case, world, rng, edge=edge, auth=auth, principal_rows=rows, decommissioned=decom)
    assert_count(case, "logs/auth/%s.log" % day, "session=%s " % sid, 2)
    assert sum(case.files[p].count("ref=%s" % ref) for p in case.files if p.startswith("logs/edge/")) == 4
    return case


def case_slowest_query():
    rng = random.Random(20260902)
    world = World(rng)
    day = DAYS[0]
    conn = "c-" + hex_id(rng, 4)
    hosts = list(world.hosts)
    early_host, right_host, other_day_host = hosts[5], hosts[41], hosts[60]
    right_service = "ledger"
    world.services[right_service] = [right_host] + world.services[right_service][:4]
    for name in world.services:
        if name != right_service and right_host in world.services[name]:
            world.services[name] = [h for h in world.services[name] if h != right_host]
    slow = {(day, 2): [(11, 4, 33, "%s conn=%s duration_ms=4180 stmt=select %s from ledger_entries where posted_at < $1 order by posted_at" % (ts(day, 11, 4, 33), conn, word(rng)))]}
    slow[(DAYS[1], 0)] = [(3, 7, 2, "%s conn=c-%s duration_ms=5310 stmt=select * from %s where %s = $1" % (ts(DAYS[1], 3, 7, 2), hex_id(rng, 4), word(rng), word(rng)))]
    pool = {day: [
        (7, 50, 0, "%s conn=%s event=open host=%s pid=4412" % (ts(day, 7, 50, 0), conn, early_host)),
        (9, 30, 5, "%s conn=%s event=close host=%s pid=4412" % (ts(day, 9, 30, 5), conn, early_host)),
        (10, 2, 44, "%s conn=%s event=open host=%s pid=9107" % (ts(day, 10, 2, 44), conn, right_host)),
        (12, 45, 0, "%s conn=%s event=close host=%s pid=9107" % (ts(day, 12, 45, 0), conn, right_host)),
    ], DAYS[1]: [(0, 20, 0, "%s conn=%s event=open host=%s pid=100" % (ts(DAYS[1], 0, 20, 0), conn, other_day_host))]}
    # Maintenance statement with a larger duration on the same day: not a query.
    prompt = ("On %s, which service issued the slowest query recorded under logs/db, and on which hostname was that "
              "connection open at the time? Spell the service as inventory/services does. "
              "Report back without changing any files." % day)
    answer = ("The slowest query on %s is the 4180 ms statement at %s on conn %s (maintenance.log's longer vacuum is not a query; "
              "%s's 5310 ms is the other day). The pool log shows %s opened %s at 10:02:44 and %s's earlier open was closed at 09:30, "
              "so the owner is %s = %s (inventory/hosts/%s.tsv), which is listed under hosts: in inventory/services/%s.yaml." % (
                  day, ts(day, 11, 4, 33), conn, DAYS[1], right_host, conn, early_host, right_host, world.hostname(right_host),
                  world.hosts[right_host][1], right_service))
    case = base_case("logjoin-slowest-query-service", prompt, [[right_service], [world.hostname(right_host)]], answer, 5,
                     "maintenance.log has a longer duration the same day; %s has a longer query on %s; the pool log's earlier open for the same conn "
                     "id names %s (%s) and the other day's open names %s; %s appears under retired_hosts of another service." % (
                         DAYS[1], DAYS[1], early_host, world.hostname(early_host), other_day_host, right_host),
                     ["db", "pool", "inventory"])
    case.add("README.md", readme("## Slow-query review\n\nThe weekly review names the service and host behind the slowest statement of each day.\n"))
    fill(case, world, rng, slow=slow, pool=pool)
    # Add right_host to a retired list explicitly after fill wrote services? fill already wrote; so rewrite that yaml.
    text = case.files["inventory/services/billing.yaml"]
    case.files["inventory/services/billing.yaml"] = text.replace("retired_hosts:\n", "retired_hosts:\n  - %s\n" % right_host, 1)
    assert_count(case, "logs/pool/%s.log" % day, "conn=%s " % conn, 4)
    assert_count(case, "logs/pool/%s.log" % DAYS[1], "conn=%s " % conn, 1)
    assert sum("  - %s" % right_host in case.files["inventory/services/%s.yaml" % n].split("retired_hosts:")[0] for n in world.services) == 1
    return case


def case_lockout_device():
    rng = random.Random(20260903)
    world = World(rng)
    day = DAYS[1]
    user = "mor" + syl_name(rng, 2) + "-17"
    right_pid, retired_pid = world.principals[88][0], world.principals[301][0]
    world.principals = [(p, user if p == right_pid else u, s, sh) for p, u, s, sh in world.principals]
    rows = [(world.principal_shard(retired_pid) , "%s\t%s\tretired" % (retired_pid, user))]
    # retired_pid keeps its own active row with a different username via world (unchanged).
    ip = "10.7.44.%d" % rng.randint(20, 200)
    macs = list(world.devices)
    morning_mac, right_mac, retired_mac = macs[12], macs[97], macs[140]
    auth = {day: [
        (8, 12, 0, "%s event=login session=s-%s principal=%s ip=10.7.44.9" % (ts(day, 8, 12, 0), hex_id(rng, 10), right_pid)),
        (14, 3, 10, "%s event=login_failed session=s-%s principal=%s ip=10.9.1.77" % (ts(day, 14, 3, 10), hex_id(rng, 10), retired_pid)),
    ]}
    for i in range(5):
        auth[day].append((14, 20, 5 + i * 9, "%s event=login_failed session=s-%s principal=%s ip=%s" % (ts(day, 14, 20, 5 + i * 9), hex_id(rng, 10), right_pid, ip)))
    auth[day].append((14, 21, 0, "%s event=lockout session=- principal=%s ip=%s" % (ts(day, 14, 21, 0), right_pid, ip)))
    dhcp = {
        (day, 6): [(15, 2, "%s DHCPACK ip=%s mac=%s lease=7200" % (ts(day, 6, 15, 2), ip, morning_mac))],
        (day, 12): [(48, 30, "%s DHCPRELEASE ip=%s mac=%s" % (ts(day, 12, 48, 30), ip, morning_mac)),
                    (59, 1, "%s DHCPACK ip=%s mac=%s lease=3600" % (ts(day, 12, 59, 1), ip, right_mac))],
        (day, 14): [(5, 0, "%s DHCPACK ip=10.9.1.77 mac=%s lease=3600" % (ts(day, 14, 5, 0), retired_mac))],
    }
    prompt = ("Account %s was locked out on %s. Which device name in inventory/devices produced the failing sign-in attempts "
              "that caused the lockout? Report back without changing any files." % (user, day))
    answer = ("%s is the active row for %s (the retired row under %s is history). The lockout at 14:21 follows five login_failed "
              "lines from %s; that address was leased to %s at 12:59 after %s released it at 12:48, and inventory/devices names %s "
              "as %s (site %s)." % (user, right_pid, retired_pid, ip, right_mac, morning_mac, right_mac, world.devices[right_mac][0], world.devices[right_mac][1]))
    case = base_case("logjoin-lockout-device", prompt, [[world.devices[right_mac][0]]], answer, 5,
                     "The retired row maps the username to %s whose failed login came from 10.9.1.77 (%s); the morning lease of %s was %s (%s); "
                     "the 08:12 successful login came from 10.7.44.9." % (retired_pid, world.devices[retired_mac][0], ip, morning_mac, world.devices[morning_mac][0]),
                     ["auth", "dhcp", "devices"])
    case.add("README.md", readme("## Lockout reviews\n\nA lockout is attributed to the device holding the source address at the time of the failed attempts.\n"))
    fill(case, world, rng, auth=auth, dhcp=dhcp, principal_rows=rows)
    assert_count(case, "logs/auth/%s.log" % day, "principal=%s ip=%s" % (right_pid, ip), 6)
    assert sum(case.files[p].count("ip=%s " % ip) for p in case.files if p.startswith("logs/dhcp/")) == 3
    return case


def case_first_5xx_build():
    rng = random.Random(20260904)
    world = World(rng)
    day = DAYS[1]
    route = "/api/exports"
    api_hosts = [h for h, v in world.hosts.items() if v[2] == "api"]
    right_host, other_host, prev_day_host = api_hosts[6], api_hosts[9], api_hosts[2]
    rels = sorted(world.releases)
    before_rel, after_rel, sibling_rel, prev_rel = rels[20], rels[21], rels[22], rels[8]
    edge = {
        (DAYS[0], 16): [(30, 0, edge_line(rng, DAYS[0], 16, 30, 0, route=route, host=prev_day_host, status=503))],
        (day, 8): [(5, 0, edge_line(rng, day, 8, 5, 0, route="/api/search", host=other_host, status=500))],
        (day, 11): [(17, 42, edge_line(rng, day, 11, 17, 42, route=route, host=right_host, status=502)),
                    (18, 3, edge_line(rng, day, 11, 18, 3, route=route, host=right_host, status=502)),
                    (40, 9, edge_line(rng, day, 11, 40, 9, route=route, host=other_host, status=502))],
        (day, 12): [(2, 2, edge_line(rng, day, 12, 2, 2, route=route, host=other_host, status=504))],
    }
    deploy = {day: [
        (9, 46, 12, "%s host=%s release=%s result=ok" % (ts(day, 9, 46, 12), world.hostname(right_host), before_rel)),
        (10, 30, 0, "%s host=%s release=%s result=ok" % (ts(day, 10, 30, 0), world.hostname(other_host), sibling_rel)),
        (15, 12, 50, "%s host=%s release=%s result=ok" % (ts(day, 15, 12, 50), world.hostname(right_host), after_rel)),
    ], DAYS[0]: [(20, 0, 0, "%s host=%s release=%s result=ok" % (ts(DAYS[0], 20, 0, 0), world.hostname(right_host), prev_rel))]}
    # The edge log for the route must be free of accidental 5xx on that day before 11:17.
    prompt = ("Route %s started returning 5xx responses on %s. Which build id was running on the host that served the first 5xx "
              "for that route that day (the build of the most recent successful deploy to that host before the failure)? "
              "Report back without changing any files." % (route, day))
    answer = ("The first 5xx on %s for %s is at %s from upstream %s (the 16:30 503 is the previous day and the 08:05 500 is /api/search). "
              "%s is %s; logs/deploy shows %s deployed there at 09:46 (after %s at 15:12 comes later, %s went to %s), and releases/%s.yaml "
              "gives build %s." % (day, route, ts(day, 11, 17, 42), right_host, right_host, world.hostname(right_host), before_rel, after_rel,
                                   sibling_rel, world.hostname(other_host), before_rel, world.releases[before_rel]))
    case = base_case("logjoin-first-5xx-build", prompt, [[world.releases[before_rel]]], answer, 5,
                     "Decoys: the previous day's 503 on %s (release %s, build %s); the later deploy %s (build %s); sibling %s on %s (build %s); "
                     "the candidates/ rc manifest for %s if present." % (prev_day_host, prev_rel, world.releases[prev_rel], after_rel, world.releases[after_rel],
                                                                       sibling_rel, other_host, world.releases[sibling_rel], before_rel),
                     ["edge", "deploy", "releases"])
    case.add("README.md", readme("## Regression reviews\n\nA regression is attributed to the build running on the first failing upstream.\n"))
    fill(case, world, rng, edge=edge, deploy=deploy)
    # Scrub accidental 5xx for the route on that day before the planted time.
    for hour in range(6, 12):
        path = "logs/edge/%s/edge-%02d.log" % (day, hour)
        lines = case.files[path].split("\n")
        fixed = []
        for line in lines:
            if "route=%s " % route in line and (" status=5" in line) and not (hour == 11 and ("11:17:42" in line or "11:18:03" in line or "11:40:09" in line)):
                line = line.replace(" ERROR ", " INFO ").replace("status=5", "status=2").replace("status=20", "status=200")
            fixed.append(line)
        case.files[path] = "\n".join(fixed)
    deploys = [l for l in case.files["logs/deploy/%s.log" % day].split("\n") if "host=%s " % world.hostname(right_host) in l]
    assert deploys == [l for l in deploys if l[11:19] in ("09:46:12", "15:12:50") or l[11:19] > "11:17:42" or l[11:19] < "09:46:12"], deploys
    assert not any("09:46:12" < l[11:19] < "11:17:42" for l in deploys), deploys
    # Make sure the rc candidate exists for before_rel to act as a decoy.
    if "releases/candidates/%s-rc1.yaml" % before_rel not in case.files:
        case.add("releases/candidates/%s-rc1.yaml" % before_rel, "release: %s-rc1\nbuild: b-%s\ndigest: sha-%s\nstatus: candidate\nnotes: never promoted\n" % (before_rel, hex_id(rng, 7), hex_id(rng, 40)))
    return case


def case_export_failure_object():
    rng = random.Random(20260905)
    world = World(rng)
    day = DAYS[0]
    tids = list(world.tenants)
    right_tid, similar_tid = tids[13], tids[27]
    base_name = syl_name(rng, 2).capitalize() + " Analytics"
    world.tenants[right_tid] = base_name
    world.tenants[similar_tid] = base_name + " Holdings"
    run1, run2, run3 = "run-" + hex_id(rng, 6), "run-" + hex_id(rng, 6), "run-" + hex_id(rng, 6)
    worker_hosts = rng.sample(list(world.hosts), 4)
    h1, h2 = worker_hosts[0], worker_hosts[2]
    obj_right = world.objects["bk-exports"][150][0]
    path_right = world.objects["bk-exports"][150][1]
    obj_run1 = world.objects["bk-exports"][40][0]
    # The same object id also exists in bk-archive with a different path.
    world.objects["bk-archive"][200] = (obj_right, "archive/2025-12/%s-%s.ndjson" % (word(rng), hex_id(rng, 4)))
    jobs = {day: [
        (1, 0, 0, "%s job=export tenant=%s run=%s status=started" % (ts(day, 1, 0, 0), right_tid, run1)),
        (1, 9, 30, "%s job=export tenant=%s run=%s status=failed" % (ts(day, 1, 9, 30), right_tid, run1)),
        (1, 10, 0, "%s job=export tenant=%s run=%s status=superseded superseded_by=%s" % (ts(day, 1, 10, 0), right_tid, run1, run2)),
        (2, 0, 0, "%s job=export tenant=%s run=%s status=started" % (ts(day, 2, 0, 0), right_tid, run2)),
        (2, 14, 8, "%s job=export tenant=%s run=%s status=failed" % (ts(day, 2, 14, 8), right_tid, run2)),
        (3, 0, 0, "%s job=export tenant=%s run=%s status=started" % (ts(day, 3, 0, 0), similar_tid, run3)),
        (3, 6, 0, "%s job=export tenant=%s run=%s status=failed" % (ts(day, 3, 6, 0), similar_tid, run3)),
    ]}
    worker = {
        (h1, day): [(1, 9, 29, "%s run=%s step=read object=%s bucket=bk-exports result=error" % (ts(day, 1, 9, 29), run1, obj_run1))],
        (h2, day): [(2, 14, 7, "%s run=%s step=read object=%s bucket=bk-exports result=error" % (ts(day, 2, 14, 7), run2, obj_right)),
                    (3, 5, 59, "%s run=%s step=upload object=%s bucket=bk-staging result=error" % (ts(day, 3, 5, 59), run3, world.objects["bk-staging"][10][0]))],
    }
    prompt = ("The nightly export for tenant \"%s\" failed on %s. Which object path (as storage/manifests records it) was the worker "
              "reading when the failure of record happened? Report back without changing any files." % (base_name, day))
    answer = ("Tenant \"%s\" is %s (\"%s Holdings\" is %s). Its %s run %s was superseded by %s, whose failure at 02:14:08 is the failure of record. "
              "logs/worker/%s shows %s reading object %s in bucket bk-exports, and storage/manifests/bk-exports lists that object as %s "
              "(the same id in bk-archive points elsewhere)." % (base_name, right_tid, base_name, similar_tid, day, run1, run2, h2, run2, obj_right, path_right))
    case = base_case("logjoin-export-failure-object", prompt, [[path_right]], answer, 5,
                     "Decoys: run %s (superseded) read %s; the similar tenant %s's run %s failed on upload in bk-staging; object %s also exists in "
                     "bk-archive with an archive/ path." % (run1, obj_run1, similar_tid, run3, obj_right),
                     ["jobs", "worker", "storage"])
    case.add("README.md", readme("## Export failures\n\nAttribute an export failure to the object the worker was reading during the failure of record.\n"))
    fill(case, world, rng, jobs=jobs, worker=worker, worker_hosts=worker_hosts, exclude_tenants=(right_tid, similar_tid))
    assert_count(case, "logs/jobs/%s.log" % day, "tenant=%s" % right_tid, 5)
    assert_count(case, "logs/worker/%s/%s.log" % (h2, day), "run=%s" % run2, 1)
    return case


def cases():
    return [case_error_ref(), case_slowest_query(), case_lockout_device(), case_first_5xx_build(), case_export_failure_object()]
