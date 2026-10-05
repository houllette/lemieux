"""config-layering-large: deep configuration trees with includes, inheritance,
overlays, environment layers and locked policy keys across ~120 files.

The generator builds the tree as data, renders it, and resolves the effective
value with the README's rules, so the reference answer is computed and every
decoy is checked to differ from it.
"""

from __future__ import annotations

import random

from common import Case, hex_id, paragraph, word, words

ENVS = ["dev", "staging", "canary", "prod"]
REGIONS = ["eu-central", "eu-west", "us-east", "apac-south"]
SECTIONS = {
    "http": ["request_timeout_ms", "max_body_bytes", "keepalive_s", "workers", "compression"],
    "db": ["pool_size", "statement_timeout_ms", "replica", "retry_limit", "ssl_mode"],
    "cache": ["ttl_seconds", "max_entries", "backend", "shard_count"],
    "features": ["checkout_variant", "search_engine", "invoice_layout", "beta_banner"],
    "logging": ["sink", "level", "sample_rate", "format"],
    "tls": ["cert_file", "key_file", "min_version", "cipher_profile"],
    "queue": ["prefetch", "visibility_s", "dead_letter", "batch_size"],
    "limits": ["rps", "burst", "concurrent_exports", "upload_mb"],
}
PROFILES = [
    "base", "service", "web", "web-hot", "web-cold", "worker", "worker-batch", "worker-stream",
    "api", "api-internal", "api-public", "edge", "edge-lite", "export", "export-bulk", "ledger",
    "ledger-audit", "search", "search-warm", "catalog", "catalog-static", "gateway", "gateway-eu",
    "gateway-us", "gateway-apac", "billing", "billing-nightly", "metrics", "metrics-sampled", "admin",
]
PARENT = {
    "base": None, "service": "base", "web": "service", "web-hot": "web", "web-cold": "web",
    "worker": "service", "worker-batch": "worker", "worker-stream": "worker", "api": "web",
    "api-internal": "api", "api-public": "api", "edge": "service", "edge-lite": "edge",
    "export": "worker-batch", "export-bulk": "export", "ledger": "worker", "ledger-audit": "ledger",
    "search": "api", "search-warm": "search", "catalog": "api", "catalog-static": "catalog",
    "gateway": "edge", "gateway-eu": "gateway", "gateway-us": "gateway", "gateway-apac": "gateway",
    "billing": "worker", "billing-nightly": "billing", "metrics": "service", "metrics-sampled": "metrics",
    "admin": "web",
}
INCLUDES = ["timeouts", "pools", "cache-defaults", "feature-defaults", "logging-defaults", "tls-defaults",
            "queue-defaults", "limits-defaults", "eu-tuning", "us-tuning", "apac-tuning", "hot-path",
            "cold-path", "batch-tuning", "audit-tuning", "compat-2025"]
OVERLAYS = ["peak-season", "maintenance", "eu-privacy", "apac-latency", "beta-cohort", "legacy-clients",
            "high-memory", "low-memory", "ledger-strict", "search-experiment"]
SINKS = ["primary", "secondary", "archive", "eu-collector", "us-collector", "apac-collector", "debug", "legacy"]


def rand_value(rng, section, key):
    if key.endswith("_ms"):
        return str(rng.choice([250, 500, 750, 1000, 1500, 2000, 3000, 4500, 6000, 9000, 12000]))
    if key.endswith("_s") or key.endswith("_seconds"):
        return str(rng.choice([15, 30, 45, 60, 90, 120, 300, 600, 900, 1800]))
    if key in ("pool_size", "workers", "retry_limit", "shard_count", "prefetch", "batch_size", "rps", "burst", "concurrent_exports", "upload_mb", "max_entries"):
        return str(rng.choice([2, 3, 4, 6, 8, 10, 12, 16, 20, 24, 32, 40, 48, 64, 96, 128, 256, 512, 1024, 2048, 4096]))
    if key == "max_body_bytes":
        return str(rng.choice([1048576, 2097152, 4194304, 8388608, 16777216]))
    if key in ("compression", "beta_banner", "dead_letter", "replica"):
        return rng.choice(["on", "off"])
    if key == "sink":
        return "@sinks/" + rng.choice(SINKS)
    if key == "level":
        return rng.choice(["debug", "info", "warn", "error"])
    if key == "sample_rate":
        return rng.choice(["0.01", "0.05", "0.1", "0.25", "0.5", "1.0"])
    if key == "format":
        return rng.choice(["json", "logfmt", "text"])
    if key == "cert_file":
        return "${CERT_DIR}/${SERVICE}-${REGION_SLUG}.pem"
    if key == "key_file":
        return "${CERT_DIR}/${SERVICE}-${REGION_SLUG}.key"
    if key == "min_version":
        return rng.choice(["1.2", "1.3"])
    if key == "cipher_profile":
        return rng.choice(["modern", "intermediate", "compat"])
    if key == "ssl_mode":
        return rng.choice(["require", "verify-full", "prefer"])
    if key == "checkout_variant":
        return rng.choice(["classic", "express", "beta", "split", "guided", "compact"])
    if key == "search_engine":
        return rng.choice(["lexical", "vector", "hybrid", "legacy"])
    if key == "invoice_layout":
        return rng.choice(["a4", "letter", "compact", "detailed"])
    if key == "backend":
        return rng.choice(["memory", "redis-like", "disk", "tiered"])
    return word(rng)


class Tree:
    def __init__(self, rng):
        self.rng = rng
        self.profiles = {p: [] for p in PROFILES}
        self.includes = {i: [] for i in INCLUDES}
        self.overlays = {o: [] for o in OVERLAYS}
        self.targets = {}
        self.policy = {e: {} for e in ENVS}
        self.sinks = {}
        self.hosts = {}
        self.archive = {}
        self.disabled = {}
        for s in SINKS:
            hid = "h-" + hex_id(rng, 4)
            self.hosts[hid] = "%s-collector-%02d.example.test" % (word(rng), rng.randint(1, 30))
            self.sinks[s] = {"host": hid, "host_legacy": "h-" + hex_id(rng, 4), "port": str(rng.randint(4000, 9000)), "proto": rng.choice(["tcp", "udp", "https"])}
        for extra in range(24):
            self.hosts["h-" + hex_id(rng, 4)] = "%s-%s-%02d.example.test" % (word(rng), rng.choice(["api", "db", "edge"]), rng.randint(1, 30))
        for s in self.sinks.values():
            self.hosts[s["host_legacy"]] = "retired-%s-%02d.example.test" % (word(rng), rng.randint(1, 30))
        for name, body in list(self.profiles.items()) + list(self.includes.items()) + list(self.overlays.items()):
            self._filler(body, name)
        for env in ENVS:
            for region in REGIONS:
                self.targets[(env, region)] = {
                    "profile": rng.choice(PROFILES[2:]),
                    "overlays": rng.sample(OVERLAYS, rng.randint(0, 2)),
                    "env": {"CERT_DIR": "/etc/%s/certs" % rng.choice(["svc", "app", "mesh"]),
                            "SERVICE": rng.choice(["api", "web", "edge", "worker"]),
                            "REGION_SLUG": region.replace("-", ""),
                            "%s__%s" % (rng.choice(list(SECTIONS)).upper(), "%s" % rng.choice(SECTIONS["limits"]).upper()): str(rng.randint(1, 500))},
                }
            for _ in range(3):
                sec = rng.choice(list(SECTIONS))
                key = rng.choice(SECTIONS[sec])
                self.policy[env][sec + "." + key] = rand_value(rng, sec, key)
        for n in range(6):
            self.archive["archive/%s-%d.conf" % (rng.choice(PROFILES), n)] = [("set", s, k, rand_value(rng, s, k)) for s in SECTIONS for k in SECTIONS[s] if rng.random() < 0.4]

    def _filler(self, body, name):
        rng = self.rng
        body.append(("comment", "%s: %s" % (name, paragraph(rng, 2))))
        n_includes = 0
        for sec in rng.sample(list(SECTIONS), rng.randint(5, 8)):
            if name in self.profiles and rng.random() < 0.35 and n_includes < 3:
                body.append(("include", rng.choice(INCLUDES)))
                n_includes += 1
            body.append(("comment", paragraph(rng, 4)))
            for key in rng.sample(SECTIONS[sec], rng.randint(2, len(SECTIONS[sec]))):
                body.append(("set", sec, key, rand_value(rng, sec, key)))
                if rng.random() < 0.5:
                    body.append(("comment", paragraph(rng, 2)))
        body.append(("comment", "history: " + paragraph(rng, 5)))

    # -- resolution ---------------------------------------------------------

    def chain(self, profile):
        out = []
        while profile:
            out.append(profile)
            profile = PARENT[profile]
        return list(reversed(out))

    def apply(self, body, values, trace, origin):
        for stmt in body:
            if stmt[0] == "include":
                self.apply(self.includes[stmt[1]], values, trace, "config/includes/%s.conf" % stmt[1])
            elif stmt[0] == "set":
                values[stmt[1] + "." + stmt[2]] = stmt[3]
                trace[stmt[1] + "." + stmt[2]] = origin

    def resolve(self, env, region):
        target = self.targets[(env, region)]
        values, trace = {}, {}
        for p in self.chain(target["profile"]):
            self.apply(self.profiles[p], values, trace, "profiles/%s.conf" % p)
        for o in target["overlays"]:
            self.apply(self.overlays[o], values, trace, "config/overlays/%s.conf" % o)
        for k, v in target["env"].items():
            if "__" in k:
                key = k.lower().replace("__", ".")
                values[key] = v
                trace[key] = "deploy/%s/%s/env.list" % (env, region)
        for k, v in self.policy[env].items():
            values[k] = v
            trace[k] = "policy/%s/locked.conf" % env
        return values, trace

    def substitute(self, value, env, region):
        target = self.targets[(env, region)]
        out = value
        for _ in range(4):
            for k, v in target["env"].items():
                out = out.replace("${%s}" % k, v)
        return out

    # -- rendering ----------------------------------------------------------

    def render_body(self, body, header=None):
        lines = []
        if header:
            lines.append(header)
        current = None
        for stmt in body:
            if stmt[0] == "comment":
                lines.append("# " + stmt[1])
            elif stmt[0] == "include":
                lines.append("include = includes/%s.conf" % stmt[1])
                current = None
            elif stmt[0] == "set":
                if current != stmt[1]:
                    lines.append("")
                    lines.append("[%s]" % stmt[1])
                    current = stmt[1]
                lines.append("%s = %s" % (stmt[2], stmt[3]))
        return "\n".join(lines) + "\n"

    def write(self, case):
        for name, body in self.profiles.items():
            header = "inherits = %s" % PARENT[name] if PARENT[name] else "# root profile"
            case.add("profiles/%s.conf" % name, self.render_body(body, header))
        for name, body in self.includes.items():
            case.add("config/includes/%s.conf" % name, self.render_body(body, "# include fragment: %s" % name))
        for name, body in self.overlays.items():
            case.add("config/overlays/%s.conf" % name, self.render_body(body, "# overlay: %s" % name))
        for path, body in self.archive.items():
            case.add("config/" + path, self.render_body(body, "# archived; not read by any target"))
        for path, body in self.disabled.items():
            case.add(path, self.render_body(body, "# disabled"))
        for (env, region), target in self.targets.items():
            case.add("deploy/%s/%s/target.conf" % (env, region),
                     "# deployment target %s/%s\nprofile = %s\noverlays = %s\nowner = team-%s\n" % (
                         env, region, target["profile"], ", ".join(target["overlays"]), word(self.rng)))
            case.add("deploy/%s/%s/env.list" % (env, region),
                     "\n".join("%s=%s" % kv for kv in target["env"].items()) + "\n")
        for env, keys in self.policy.items():
            case.add("policy/%s/locked.conf" % env, "# keys listed here are fixed for every %s target; the value here wins over every other layer\n" % env +
                     "".join("%s = %s\n" % kv for kv in keys.items()))
        for name, s in self.sinks.items():
            case.add("config/sinks/%s.conf" % name, "# log sink %s\nhost = %s\nhost_legacy = %s\nport = %s\nproto = %s\n" % (name, s["host"], s["host_legacy"], s["port"], s["proto"]))
        rows = ["host_id\thostname\tstatus"]
        for hid, hn in self.hosts.items():
            rows.append("%s\t%s\t%s" % (hid, hn, "retired" if hn.startswith("retired-") else "in-service"))
        case.add("inventory/hosts.tsv", "\n".join(rows) + "\n")

    def keys_reference(self, rng):
        lines = ["# Key reference", "", "Every key the loader understands, its section, and the value it takes when no layer sets it. "
                 "These documented fallbacks are the loader's compiled-in defaults, not what any target runs with.", ""]
        for sec, keys in SECTIONS.items():
            lines.append("## [%s]" % sec)
            lines.append("")
            for key in keys:
                lines.append("### %s.%s" % (sec, key))
                lines.append("")
                lines.append("Compiled-in default: `%s`." % rand_value(rng, sec, key))
                lines.append("")
                lines.append(paragraph(rng, 6))
                lines.append("")
                lines.append(paragraph(rng, 5))
                lines.append("")
                lines.append("Seen in practice: " + ", ".join("`%s` (%s/%s)" % (rand_value(rng, sec, key), rng.choice(ENVS), rng.choice(REGIONS)) for _ in range(4)) + ".")
                lines.append("")
                lines.append(paragraph(rng, 5))
                lines.append("")
        return "\n".join(lines) + "\n"


README = """# Configuration tree

The loader assembles one flat set of `section.key` values per deployment
target. The rules below are the whole algorithm; nothing else contributes.

1. `deploy/<env>/<region>/target.conf` names the `profile` and an optional
   comma-separated list of `overlays`.
2. Profiles live in `profiles/<name>.conf`. A profile whose first line is
   `inherits = <parent>` is applied after its parent; the chain is resolved
   root first, so a child's values win over its ancestors.
3. Inside any file, statements apply top to bottom. `include =
   includes/<name>.conf` splices `config/includes/<name>.conf` in at that
   point: a key set above the include is overridden by the included file,
   and a key set below the include overrides it.
4. Overlays (`config/overlays/<name>.conf`) apply after the whole profile
   chain, in the order the target lists them.
5. `deploy/<env>/<region>/env.list` applies after the overlays. A line
   `SECTION__KEY=value` sets `section.key`; every other line is a plain
   variable used only for `${VAR}` substitution.
6. `policy/<env>/locked.conf` applies last. A key listed there takes the
   policy file's value for every target of that environment, whatever any
   other layer says.
7. Files under `config/archive/` and any file ending in `.disabled` are
   never read.
8. A value of the form `@sinks/<name>` names `config/sinks/<name>.conf`,
   whose `host =` is a host id resolved through `inventory/hosts.tsv`.
   `host_legacy` is the id the sink used before the collector migration.
9. `${VAR}` in a value is substituted from the target's env.list after all
   layers are applied.

`docs/keys-reference.md` documents every key and the loader's compiled-in
fallback, which is only used when no layer at all sets the key.
"""


def make_case(cid, seed, key, env, region, plant, prompt_fn, tags, min_files):
    rng = random.Random(seed)
    tree = Tree(rng)
    story = plant(tree, rng)
    values, trace = tree.resolve(env, region)
    effective = values[key]
    decoys = story["decoys"]
    resolved = story.get("resolve", lambda v: v)(effective)
    for label, val in decoys.items():
        assert val != resolved, "%s: decoy %s equals the answer %r" % (cid, label, val)
        assert resolved not in val and val not in resolved, "%s: decoy %s overlaps the answer %r" % (cid, label, val)
    case = Case(cid, "config-layering-large", prompt_fn(resolved, trace[key]), story["tokens"](resolved, trace[key]),
                story["answer"](resolved, trace[key], values, trace), min_files,
                "Decoys: " + "; ".join("%s gives %s" % (k, v) for k, v in decoys.items()) + ".",
                ["config", "layering"] + tags)
    case.add("README.md", README)
    case.add("docs/keys-reference.md", tree.keys_reference(rng))
    case.add("docs/rollout-notes.md", "# Rollout notes\n\n" + "\n\n".join(paragraph(rng, 5) for _ in range(12)) + "\n")
    for e in ENVS:
        for r in REGIONS:
            case.add("docs/rollouts/%s/%s.md" % (e, r), "# %s / %s\n\nTarget profile at last review: %s.\n\n" % (e, r, rng.choice(PROFILES)) +
                     "\n\n".join(paragraph(rng, 6) for _ in range(8)) + "\n")
    for month in range(3, 9):
        entries = []
        for _ in range(22):
            sec = rng.choice(list(SECTIONS)); k = rng.choice(SECTIONS[sec])
            entries.append("- 2026-%02d-%02d: proposed %s.%s = %s for %s/%s (%s). %s" % (
                month, rng.randint(1, 28), sec, k, rand_value(rng, sec, k), rng.choice(ENVS), rng.choice(REGIONS),
                rng.choice(["applied", "reverted", "withdrawn", "superseded"]), paragraph(rng, 3)))
        case.add("history/changes-2026-%02d.md" % month, "# Change log 2026-%02d\n\nProposals as discussed; the tree is authoritative, not this log.\n\n" % month + "\n".join(entries) + "\n")
    tree.write(case)
    return case


def strip_key(body, sec, key):
    return [s for s in body if not (s[0] == "set" and s[1] == sec and s[2] == key)]


def case_request_timeout():
    env, region, key = "prod", "eu-central", "http.request_timeout_ms"

    def plant(tree, rng):
        tree.targets[(env, region)] = {"profile": "gateway-eu", "overlays": ["eu-privacy"],
                                       "env": {"CERT_DIR": "/etc/mesh/certs", "SERVICE": "gateway", "REGION_SLUG": "eucentral", "LIMITS__RPS": "900"}}
        tree.policy[env].pop(key, None)
        for p in tree.chain("gateway-eu"):
            tree.profiles[p] = strip_key(tree.profiles[p], "http", "request_timeout_ms")
        for i in INCLUDES:
            tree.includes[i] = strip_key(tree.includes[i], "http", "request_timeout_ms")
        tree.overlays["eu-privacy"] = strip_key(tree.overlays["eu-privacy"], "http", "request_timeout_ms")
        tree.profiles["base"].append(("set", "http", "request_timeout_ms", "3000"))
        tree.profiles["gateway"].append(("set", "http", "request_timeout_ms", "9000"))
        # Leaf sets 1500, then includes eu-tuning which sets 4500: the include wins.
        tree.profiles["gateway-eu"] = [("comment", "EU gateway: tightened timeouts after the 2026-06 review"),
                                       ("set", "http", "request_timeout_ms", "1500"),
                                       ("include", "eu-tuning")] + [s for s in tree.profiles["gateway-eu"] if s[0] != "include"]
        tree.includes["eu-tuning"].insert(1, ("set", "http", "request_timeout_ms", "4500"))
        tree.targets[("prod", "eu-west")]["env"]["HTTP__REQUEST_TIMEOUT_MS"] = "6000"
        tree.targets[("staging", "eu-central")]["env"]["HTTP__REQUEST_TIMEOUT_MS"] = "2000"
        tree.disabled["profiles/gateway-eu.conf.disabled"] = [("set", "http", "request_timeout_ms", "12000")]
        return {"decoys": {"profiles/base.conf": "3000", "profiles/gateway.conf": "9000", "the leaf's own line before the include": "1500",
                           "deploy/prod/eu-west/env.list": "6000", "deploy/staging/eu-central/env.list": "2000", "the .disabled leaf": "12000"},
                "tokens": lambda v, t: [[v], ["eu-tuning"]],
                "answer": lambda v, t, values, trace: (
                    "http.request_timeout_ms is %s for prod/eu-central, set by %s. The target uses profile gateway-eu (chain base -> service -> edge -> gateway -> gateway-eu); "
                    "base sets 3000 and gateway 9000, the leaf sets 1500 but then includes eu-tuning, and an include below a key overrides it (README rule 3). "
                    "The eu-privacy overlay, the env.list and policy/prod/locked.conf do not touch the key; prod/eu-west's 6000 is another region and the .disabled file is never read." % (v, t))}

    prompt = lambda v, t: ("What http.request_timeout_ms is in effect for the prod deployment in eu-central once every layer under profiles/, config/, deploy/ "
                           "and policy/ is applied, and which file sets that value? Report back without changing any files.")
    return make_case("cfglarge-request-timeout-prod-eu", 20260911, key, env, region, plant, prompt, ["include-order"], 6)


def case_locked_pool_size():
    env, region, key = "staging", "us-west" if "us-west" in REGIONS else "us-east", "db.pool_size"

    def plant(tree, rng):
        tree.targets[(env, region)] = {"profile": "ledger-audit", "overlays": ["ledger-strict", "high-memory"],
                                       "env": {"CERT_DIR": "/etc/app/certs", "SERVICE": "ledger", "REGION_SLUG": region.replace("-", ""), "DB__POOL_SIZE": "96"}}
        for p in tree.chain("ledger-audit"):
            tree.profiles[p] = strip_key(tree.profiles[p], "db", "pool_size")
        for i in INCLUDES:
            tree.includes[i] = strip_key(tree.includes[i], "db", "pool_size")
        for o in OVERLAYS:
            tree.overlays[o] = strip_key(tree.overlays[o], "db", "pool_size")
        tree.profiles["service"].append(("set", "db", "pool_size", "8"))
        tree.profiles["ledger"].append(("set", "db", "pool_size", "24"))
        tree.overlays["ledger-strict"].append(("set", "db", "pool_size", "12"))
        tree.overlays["high-memory"].append(("set", "db", "pool_size", "64"))
        tree.policy[env]["db.pool_size"] = "20"
        tree.policy["prod"]["db.pool_size"] = "40"
        return {"decoys": {"profiles/service.conf": "8", "profiles/ledger.conf": "24", "overlay ledger-strict": "12", "overlay high-memory": "64",
                           "deploy/%s/%s/env.list" % (env, region): "96", "policy/prod/locked.conf": "40"},
                "tokens": lambda v, t: [[v], [t]],
                "answer": lambda v, t, values, trace: (
                    "db.pool_size is %s for %s/%s, fixed by %s. The chain (service 8, ledger 24) and the overlays ledger-strict 12 then high-memory 64 are all "
                    "overridden by env.list's DB__POOL_SIZE=96, but the key is locked for %s so the policy value wins (README rule 6). prod's locked value 40 "
                    "applies to prod targets only." % (v, env, region, t, env))}

    prompt = lambda v, t: ("What db.pool_size does the %s deployment in %s actually run with after every configuration layer is applied, and which "
                           "file decides it? Report back without changing any files." % (env, region))
    return make_case("cfglarge-locked-pool-size", 20260912, key, env, region, plant, prompt, ["locked-policy"], 6)


def case_overlay_order():
    env, region, key = "prod", "apac-south", "features.checkout_variant"

    def plant(tree, rng):
        tree.targets[(env, region)] = {"profile": "api-public", "overlays": ["beta-cohort", "apac-latency"],
                                       "env": {"CERT_DIR": "/etc/svc/certs", "SERVICE": "api", "REGION_SLUG": "apacsouth", "CACHE__TTL_SECONDS": "45"}}
        tree.policy[env].pop(key, None)
        for p in tree.chain("api-public"):
            tree.profiles[p] = strip_key(tree.profiles[p], "features", "checkout_variant")
        for i in INCLUDES:
            tree.includes[i] = strip_key(tree.includes[i], "features", "checkout_variant")
        for o in OVERLAYS:
            tree.overlays[o] = strip_key(tree.overlays[o], "features", "checkout_variant")
        tree.profiles["web"].append(("set", "features", "checkout_variant", "classic"))
        tree.profiles["api-public"].append(("include", "feature-defaults"))
        tree.includes["feature-defaults"].append(("set", "features", "checkout_variant", "express"))
        tree.overlays["beta-cohort"].append(("set", "features", "checkout_variant", "beta"))
        tree.overlays["apac-latency"].append(("set", "features", "checkout_variant", "compact"))
        tree.overlays["search-experiment"].append(("set", "features", "checkout_variant", "split"))
        tree.targets[("canary", region)]["env"]["FEATURES__CHECKOUT_VARIANT"] = "guided"
        tree.archive["archive/api-public-prod.conf"] = [("set", "features", "checkout_variant", "guided")]
        return {"decoys": {"profiles/web.conf": "classic", "config/includes/feature-defaults.conf": "express", "overlay beta-cohort (listed first)": "beta",
                           "overlay search-experiment (not listed)": "split", "deploy/canary/apac-south/env.list": "guided", "config/archive": "guided"},
                "tokens": lambda v, t: [[v], ["apac-latency"]],
                "answer": lambda v, t, values, trace: (
                    "features.checkout_variant is %s for prod/apac-south, set by %s. profiles/web.conf sets classic, the feature-defaults include in api-public sets express, "
                    "and the target lists overlays beta-cohort then apac-latency, so apac-latency's compact is applied last (README rule 4). "
                    "canary/apac-south's env.list guided belongs to another env, search-experiment is not listed, and the archive is never read." % (v, t))}

    prompt = lambda v, t: ("Which features.checkout_variant does the prod deployment in apac-south end up with once the profile chain, overlays, "
                           "env.list and policy are applied, and which file supplies it? Report back without changing any files.")
    return make_case("cfglarge-overlay-order-variant", 20260913, key, env, region, plant, prompt, ["overlays"], 6)


def case_log_sink_hostname():
    env, region, key = "canary", "eu-west", "logging.sink"

    def plant(tree, rng):
        tree.targets[(env, region)] = {"profile": "search-warm", "overlays": ["maintenance"],
                                       "env": {"CERT_DIR": "/etc/svc/certs", "SERVICE": "search", "REGION_SLUG": "euwest", "QUEUE__PREFETCH": "16"}}
        tree.policy[env].pop(key, None)
        for p in tree.chain("search-warm"):
            tree.profiles[p] = strip_key(tree.profiles[p], "logging", "sink")
        for i in INCLUDES:
            tree.includes[i] = strip_key(tree.includes[i], "logging", "sink")
        for o in OVERLAYS:
            tree.overlays[o] = strip_key(tree.overlays[o], "logging", "sink")
        tree.profiles["base"].append(("set", "logging", "sink", "@sinks/primary"))
        tree.profiles["search"].append(("set", "logging", "sink", "@sinks/eu-collector"))
        tree.disabled["profiles/search-warm.conf.disabled"] = [("set", "logging", "sink", "@sinks/debug")]
        tree.overlays["low-memory"].append(("set", "logging", "sink", "@sinks/archive"))
        tree.policy["prod"]["logging.sink"] = "@sinks/secondary"
        return {"decoys": {"profiles/base.conf": tree.hosts[tree.sinks["primary"]["host"]],
                           "the .disabled leaf (@sinks/debug)": tree.hosts[tree.sinks["debug"]["host"]],
                           "overlay low-memory (not listed)": tree.hosts[tree.sinks["archive"]["host"]],
                           "policy/prod/locked.conf (@sinks/secondary)": tree.hosts[tree.sinks["secondary"]["host"]],
                           "eu-collector's host_legacy": tree.hosts[tree.sinks["eu-collector"]["host_legacy"]]},
                "resolve": lambda v: tree.hosts[tree.sinks[v.split("/")[1]]["host"]],
                "tokens": lambda v, t: [[v]],
                "answer": lambda v, t, values, trace: (
                    "canary/eu-west uses profile search-warm (base -> service -> web -> api -> search -> search-warm). base sets @sinks/primary, search sets @sinks/eu-collector, "
                    "and nothing later (maintenance overlay, env.list, policy/canary) touches logging.sink; the .disabled leaf file is never read. "
                    "config/sinks/eu-collector.conf names host %s, which inventory/hosts.tsv resolves to %s (host_legacy is the pre-migration id)." % (
                        tree.sinks["eu-collector"]["host"], v))}

    prompt = lambda v, t: ("Which hostname does the canary deployment in eu-west ship its logs to once logging.sink is resolved through every layer, "
                           "the sink file and the host inventory? Report back without changing any files.")
    return make_case("cfglarge-log-sink-hostname", 20260914, key, env, region, plant, prompt, ["sinks", "inventory"], 6)


def case_cert_path():
    env, region, key = "prod", "us-east", "tls.cert_file"

    def plant(tree, rng):
        tree.targets[(env, region)] = {"profile": "gateway-us", "overlays": ["legacy-clients"],
                                       "env": {"CERT_DIR": "/etc/mesh/certs", "SERVICE": "gateway", "REGION_SLUG": "useast1", "TLS__MIN_VERSION": "1.3"}}
        tree.policy[env].pop(key, None)
        for p in tree.chain("gateway-us"):
            tree.profiles[p] = strip_key(tree.profiles[p], "tls", "cert_file")
        for i in INCLUDES:
            tree.includes[i] = strip_key(tree.includes[i], "tls", "cert_file")
        for o in OVERLAYS:
            tree.overlays[o] = strip_key(tree.overlays[o], "tls", "cert_file")
        tree.profiles["base"].append(("set", "tls", "cert_file", "${CERT_DIR}/${SERVICE}.pem"))
        tree.profiles["gateway"].append(("include", "tls-defaults"))
        tree.includes["tls-defaults"].append(("set", "tls", "cert_file", "${CERT_DIR}/${SERVICE}-${REGION_SLUG}.pem"))
        tree.overlays["legacy-clients"].append(("set", "tls", "cert_file", "${CERT_DIR}/legacy/${SERVICE}-${REGION_SLUG}-compat.pem"))
        tree.overlays["peak-season"].append(("set", "tls", "cert_file", "${CERT_DIR}/peak/${SERVICE}.pem"))
        tree.targets[("prod", "eu-west")]["env"].update({"CERT_DIR": "/etc/mesh/certs", "SERVICE": "gateway", "REGION_SLUG": "euwest"})
        tree.targets[("canary", region)]["env"].update({"CERT_DIR": "/etc/canary/certs", "SERVICE": "gateway", "REGION_SLUG": "useast1"})
        return {"decoys": {"profiles/base.conf": "/etc/mesh/certs/gateway.pem", "config/includes/tls-defaults.conf": "/etc/mesh/certs/gateway-useast1.pem",
                           "overlay peak-season (not listed)": "/etc/mesh/certs/peak/gateway.pem",
                           "canary/us-east's CERT_DIR": "/etc/canary/certs/legacy/gateway-useast1-compat.pem",
                           "prod/eu-west's REGION_SLUG": "/etc/mesh/certs/legacy/gateway-euwest-compat.pem"},
                "resolve": lambda v: tree.substitute(v, env, region),
                "tokens": lambda v, t: [[v]],
                "answer": lambda v, t, values, trace: (
                    "tls.cert_file for prod/us-east is %s. The chain ends at gateway-us; base sets ${CERT_DIR}/${SERVICE}.pem, gateway's tls-defaults include sets the "
                    "regional template, and the listed overlay legacy-clients sets ${CERT_DIR}/legacy/${SERVICE}-${REGION_SLUG}-compat.pem last (peak-season is not listed). "
                    "deploy/prod/us-east/env.list supplies CERT_DIR=/etc/mesh/certs, SERVICE=gateway and REGION_SLUG=useast1 (README rule 9)." % v)}

    prompt = lambda v, t: ("Which file path does the prod deployment in us-east load its TLS certificate from, after tls.cert_file is resolved through "
                           "every layer and its ${VAR} placeholders are substituted? Report back without changing any files.")
    return make_case("cfglarge-cert-path-vars", 20260915, key, env, region, plant, prompt, ["variables"], 6)


def cases():
    return [case_request_timeout(), case_locked_pool_size(), case_overlay_order(), case_log_sink_hostname(), case_cert_path()]
