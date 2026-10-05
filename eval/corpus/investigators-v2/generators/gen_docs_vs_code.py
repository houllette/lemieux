"""docs-vs-code-large: a documentation tree that disagrees with the code in
specific places. The answer is what the code does, reached through a
configuration table or profile the docs never mention.
"""

from __future__ import annotations

import random

from common import Case, hex_id, paragraph, py_module, sentence, word, words

SRC = {
    "src/api": ["accounts", "listing", "orders", "sessions", "webhooks_api", "health"],
    "src/errors": ["classes", "mapping", "render", "legacy_codes"],
    "src/http": ["server", "headers", "responses", "routing"],
    "src/http/middleware": ["ratelimit", "ratelimit_legacy", "auth", "tracing", "compression"],
    "src/webhooks": ["dispatch", "queue", "retry", "signers_legacy"],
    "src/webhooks/signers": ["v1", "v2", "none"],
    "src/cli": ["main", "sync", "exit_codes", "output", "compat"],
    "src/cli/tables": ["default", "strict", "lenient"],
    "src/core": ["settings", "clock", "ids", "validation"],
    "src/storage": ["items", "accounts", "events"],
}
DOC_PAGES = ["overview", "authentication", "accounts", "errors", "rate-limits", "pagination", "webhooks", "cli", "sync", "exports", "sessions", "orders", "health", "versioning", "changelog-policy", "glossary"]


def build_tree(case, rng, specials):
    for pkg, mods in SRC.items():
        if pkg + "/__init__.py" not in specials:
            case.add(pkg + "/__init__.py", "")
        for m in mods:
            path = "%s/%s.py" % (pkg, m)
            if path not in specials:
                case.add(path, py_module(rng, path[:-3].replace("/", ".")))
    for path, content in specials.items():
        case.add(path, content)
    case.add("src/__init__.py", "")
    for page in DOC_PAGES:
        if "docs/%s.md" % page not in specials:
            case.add("docs/%s.md" % page, "# %s\n\n" % page.replace("-", " ").title() + "\n\n".join(paragraph(rng, 5) for _ in range(11)) + "\n")
    for n, guide in enumerate(["quickstart", "deploying", "upgrading", "troubleshooting", "security", "observability", "backups", "faq"]):
        case.add("docs/guides/%s.md" % guide, "# %s\n\n" % guide.title() + "\n\n".join("%d. %s" % (i + 1, paragraph(rng, 4)) for i in range(9)) + "\n")
    lines = ["# Endpoint reference", "", "Generated from the route table on 2025-11-02; values may lag the code.", ""]
    for _ in range(95):
        lines += ["## %s /%s/%s" % (rng.choice(["GET", "POST", "PUT", "DELETE"]), word(rng), word(rng)), "", paragraph(rng, 4), "",
                  "| Field | Type | Default |", "| --- | --- | --- |"] + ["| %s | %s | %s |" % (word(rng), rng.choice(["string", "integer", "boolean"]), rng.choice(["-", "0", "50", "true", "none"])) for _ in range(5)] + [""]
    case.add("docs/reference/endpoints.md", "\n".join(lines) + "\n")
    keys = ["# Configuration keys", "", "Every key under config/ with the value the 2025 deployment used. Current files win over this page.", ""]
    for _ in range(70):
        keys += ["## %s.%s" % (word(rng), word(rng)), "", "2025 value: `%s`." % rng.choice([str(rng.randint(1, 500)), word(rng), "on", "off"]), "", paragraph(rng, 5), ""]
    case.add("docs/reference/config-keys.md", "\n".join(keys) + "\n")
    for n in range(8):
        case.add("docs/adr/%03d-%s.md" % (n + 1, word(rng)), "# ADR %03d\n\nStatus: %s\n\n" % (n + 1, rng.choice(["accepted", "superseded", "proposed"])) + "\n\n".join(paragraph(rng, 5) for _ in range(6)) + "\n")
    for n in range(8):
        case.add("changelog/2026-%02d.md" % (n + 1), "# 2026-%02d\n\n" % (n + 1) + "\n".join("- %s" % sentence(rng) for _ in range(40)) + "\n")
    for n in range(12):
        case.add("tests/test_%s.py" % word(rng) + str(n), "def test_%s():\n    assert True\n\n\ndef test_%s_%d():\n    assert 1 + 1 == 2\n" % (word(rng), word(rng), n))


def case_duplicate_email_status():
    rng = random.Random(20260951)
    specials = {
        "src/api/accounts.py": py_module(rng, "src.api.accounts", '''
def register(payload):
    """Create an account; a second registration for the same email is refused."""
    from src.errors.classes import DuplicateAccount
    from src.storage.accounts import exists, insert
    if exists(payload["email"]):
        raise DuplicateAccount(payload["email"])
    return insert(payload)
'''),
        "src/errors/classes.py": py_module(rng, "src.errors.classes", '''
class ApiError(Exception):
    """Base error. `code` is looked up in config/error-codes.tsv by the renderer."""
    code = "generic"
    default_status = 500


class ConflictError(ApiError):
    code = "conflict"
    default_status = 409


class DuplicateAccount(ConflictError):
    """Raised by register(); carries its own code, which the table maps separately."""
    code = "account.duplicate"


class NotFound(ApiError):
    code = "not_found"
    default_status = 404
'''),
        "src/errors/render.py": py_module(rng, "src.errors.render", '''
def render(error):
    """Turn an ApiError into a response; the status comes from the code table, else default_status."""
    from src.errors.mapping import status_for
    status = status_for(error.code, error.default_status)
    return {"status": status, "body": {"code": error.code, "message": str(error)}}
'''),
        "src/errors/mapping.py": py_module(rng, "src.errors.mapping", '''
import os

_TABLE = os.path.join(os.path.dirname(__file__), "..", "..", "config", "error-codes.tsv")


def status_for(code, fallback):
    """Exact code first, then the code's prefix before the first dot, then the fallback."""
    table = _load()
    if code in table:
        return table[code]
    prefix = code.split(".", 1)[0]
    return table.get(prefix, fallback)


def _load():
    out = {}
    with open(_TABLE) as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            code, status = line.rstrip("\\n").split("\\t")
            out[code] = int(status)
    return out
'''),
        "src/errors/legacy_codes.py": py_module(rng, "src.errors.legacy_codes", '''
LEGACY = {"account.duplicate": 409, "conflict": 409, "not_found": 404}
'''),
        "config/error-codes.tsv": "# code\tstatus\naccount\t400\naccount.duplicate\t422\naccount.locked\t423\nconflict\t409\nnot_found\t404\nrate_limited\t429\n",
        "docs/accounts.md": "# Accounts\n\n`POST /accounts` returns **409 Conflict** when the email is already registered.\n\n" + paragraph(rng, 6) + "\n",
        "docs/errors.md": "# Errors\n\n| code | status |\n| --- | --- |\n| account.duplicate | 409 |\n| conflict | 409 |\n| not_found | 404 |\n\n" + paragraph(rng, 6) + "\n",
    }
    case = Case("docslarge-duplicate-email-status", "docs-vs-code-large",
                "What HTTP status code does the API actually return when POST /accounts is called with an email that is already registered? Follow the code, not the docs. "
                "Report back without changing any files.",
                [["422"]],
                "register() raises DuplicateAccount, whose code is account.duplicate. render() asks mapping.status_for, which finds the exact code in config/error-codes.tsv: 422. "
                "The docs' 409, ConflictError.default_status 409, the `account` prefix row 400 and src/errors/legacy_codes.py's 409 are not what is returned.", 5,
                "Decoys: docs/accounts.md and docs/errors.md (409); ConflictError.default_status (409); the `account` prefix row (400); src/errors/legacy_codes.py (409).",
                ["docs", "api", "status-code"])
    case.add("README.md", "# accounts-api\n\nFictional service. Documentation under docs/ is best effort; the code is authoritative.\n")
    build_tree(case, rng, specials)
    return case


def case_rate_limit_header():
    rng = random.Random(20260952)
    specials = {
        "src/http/middleware/ratelimit.py": py_module(rng, "src.http.middleware.ratelimit", '''
def apply(request, response, bucket):
    """Attach limit headers. The reset header's name comes from the headers table; its value is milliseconds until reset."""
    from src.http.headers import name
    from src.core.clock import now_ms
    response.headers[name("limit")] = str(bucket.limit)
    response.headers[name("remaining")] = str(bucket.remaining)
    response.headers[name("reset")] = str(max(0, bucket.reset_at_ms - now_ms()))
    return response
'''),
        "src/http/middleware/ratelimit_legacy.py": py_module(rng, "src.http.middleware.ratelimit_legacy", '''
def apply(request, response, bucket):
    """Pre-2026 middleware: seconds, fixed header names. Not mounted; see src/http/server.py."""
    response.headers["X-RateLimit-Reset"] = str(int(bucket.reset_at_ms / 1000))
    return response
'''),
        "src/http/server.py": py_module(rng, "src.http.server", '''
def middleware_stack():
    """Mounted middleware, outermost first."""
    from src.http.middleware import tracing, auth, ratelimit, compression
    return [tracing.apply, auth.apply, ratelimit.apply, compression.apply]
'''),
        "src/http/headers.py": py_module(rng, "src.http.headers", '''
import os

_CONF = os.path.join(os.path.dirname(__file__), "..", "..", "config", "headers.conf")


def name(kind):
    """Header name for `kind` from config/headers.conf ([ratelimit] section)."""
    section = None
    with open(_CONF) as fh:
        for line in fh:
            line = line.split("#", 1)[0].strip()
            if line.startswith("["):
                section = line.strip("[]")
            elif "=" in line and section == "ratelimit":
                k, v = (p.strip() for p in line.split("=", 1))
                if k == kind:
                    return v
    raise KeyError(kind)
'''),
        "config/headers.conf": "[tracing]\nrequest_id = X-Request-Id\n\n[ratelimit]\nlimit = X-Quota-Limit\nremaining = X-Quota-Remaining\nreset = X-Quota-Reset\n\n[compat]\nreset = X-RateLimit-Reset  # only read by the legacy middleware, which is not mounted\n",
        "config/headers.conf.dist": "[ratelimit]\nlimit = X-RateLimit-Limit\nremaining = X-RateLimit-Remaining\nreset = X-RateLimit-Reset\n",
        "docs/rate-limits.md": "# Rate limits\n\nResponses carry `X-RateLimit-Reset`, the number of **seconds** until the window resets.\n\n" + paragraph(rng, 6) + "\n",
    }
    case = Case("docslarge-rate-limit-reset-header", "docs-vs-code-large",
                "Which response header does the mounted rate-limit middleware actually use to report the time until the limit resets, and in what unit is its value? "
                "Report back without changing any files.",
                [["x-quota-reset"], ["millisecond", " ms"]],
                "src/http/server.py mounts src/http/middleware/ratelimit.py (not ratelimit_legacy). It sets headers by name('reset'), which reads the [ratelimit] section of "
                "config/headers.conf: X-Quota-Reset, and the value is reset_at_ms - now_ms(), i.e. milliseconds. The docs' X-RateLimit-Reset in seconds describes the unmounted "
                "legacy middleware, the [compat] section and headers.conf.dist.", 5,
                "Decoys: docs/rate-limits.md (X-RateLimit-Reset, seconds); ratelimit_legacy.py (same, and not mounted); the [compat] section and config/headers.conf.dist.",
                ["docs", "http", "headers"])
    case.add("README.md", "# quota-api\n\nFictional service. Documentation under docs/ is best effort; the code is authoritative.\n")
    build_tree(case, rng, specials)
    return case


def case_webhook_signature():
    rng = random.Random(20260953)
    specials = {
        "src/webhooks/dispatch.py": py_module(rng, "src.webhooks.dispatch", '''
def deliver(event, body):
    """Sign and post one webhook using the configured signing profile."""
    from src.core.settings import setting
    from src.webhooks.signers import SIGNERS
    signer = SIGNERS[setting("signing_profile")]
    headers = {"X-Signature": signer.sign(body)}
    return _post(event, body, headers)


def _post(event, body, headers):
    return {"event": event, "headers": headers}
'''),
        "src/webhooks/signers/__init__.py": '''"""Signer registry keyed by profile name."""

from src.webhooks.signers import v1, v2, none

SIGNERS = {"v1": v1, "v2": v2, "none": none, "hmac": v1}
''',
        "src/webhooks/signers/v1.py": py_module(rng, "src.webhooks.signers.v1", '''
import hmac


def sign(body):
    """HMAC-SHA256 over the raw body, hex encoded."""
    return hmac.new(b"key", body, "sha256").hexdigest()
'''),
        "src/webhooks/signers/v2.py": py_module(rng, "src.webhooks.signers.v2", '''
import hmac


def sign(body):
    """HMAC-SHA512 over timestamp + body, base64 encoded."""
    return hmac.new(b"key", body, "sha512").hexdigest()
'''),
        "src/webhooks/signers/none.py": "def sign(body):\n    return \"\"\n",
        "src/webhooks/signers_legacy.py": py_module(rng, "src.webhooks.signers_legacy", '''
def sign(body):
    """Old MD5-style signature; unreferenced."""
    return "legacy"
'''),
        "src/core/settings.py": py_module(rng, "src.core.settings", '''
import os

_CONF = os.path.join(os.path.dirname(__file__), "..", "..", "config", "settings.conf")


def setting(name):
    """Read config/settings.conf; the [overrides] section beats the [defaults] section."""
    values = {}
    section = None
    with open(_CONF) as fh:
        for line in fh:
            line = line.split("#", 1)[0].strip()
            if line.startswith("["):
                section = line.strip("[]")
            elif "=" in line:
                k, v = (p.strip() for p in line.split("=", 1))
                values.setdefault(k, {})[section] = v
    entry = values[name]
    return entry.get("overrides", entry.get("defaults"))
'''),
        "config/settings.conf": "[defaults]\nsigning_profile = v1\nwebhook_retries = 5\n%s\n[overrides]\nsigning_profile = v2\n" % "\n".join("%s = %s" % (word(rng), word(rng)) for _ in range(15)),
        "config/settings.conf.example": "[defaults]\nsigning_profile = v1\n",
        "docs/webhooks.md": "# Webhooks\n\nPayloads are signed with **HMAC-SHA256** (profile `v1`); verify `X-Signature` accordingly.\n\n" + paragraph(rng, 6) + "\n",
    }
    case = Case("docslarge-webhook-signature-algo", "docs-vs-code-large",
                "Which signing algorithm does the webhook dispatcher actually use for X-Signature once the configured signing profile is resolved? Name the HMAC hash. "
                "Report back without changing any files.",
                [["sha512"]],
                "dispatch.deliver picks SIGNERS[setting('signing_profile')]; settings.setting prefers the [overrides] section of config/settings.conf, where signing_profile = v2. "
                "src/webhooks/signers/v2.py signs with hmac sha512. The docs, the [defaults] v1 and settings.conf.example describe HMAC-SHA256.", 5,
                "Decoys: docs/webhooks.md (HMAC-SHA256); [defaults] signing_profile = v1 and config/settings.conf.example; the `hmac` alias in SIGNERS (v1); signers_legacy.py.",
                ["docs", "webhooks", "crypto"])
    case.add("README.md", "# hooks-service\n\nFictional service. Documentation under docs/ is best effort; the code is authoritative.\n")
    build_tree(case, rng, specials)
    return case


def case_default_page_size():
    rng = random.Random(20260954)
    specials = {
        "src/api/listing.py": py_module(rng, "src.api.listing", '''
def list_items(params):
    """GET /items. The page size falls back to the configured default and is then clamped."""
    from src.api.defaults import DEFAULTS
    from src.core.validation import clamp
    from src.core.settings import limit
    size = int(params.get("page_size", DEFAULTS["page_size"]))
    size = clamp(size, 1, limit("max_page_size"))
    return {"page_size": size}
'''),
        "src/api/defaults.py": py_module(rng, "src.api.defaults", '''
import os

_CONF = os.path.join(os.path.dirname(__file__), "..", "..", "config", "api.conf")


def _load():
    out = {"page_size": 100}  # compiled-in fallback, overridden by config/api.conf
    with open(_CONF) as fh:
        for line in fh:
            line = line.split("#", 1)[0].strip()
            if "=" in line:
                k, v = (p.strip() for p in line.split("=", 1))
                out[k] = int(v) if v.isdigit() else v
    return out


DEFAULTS = _load()
'''),
        "src/core/validation.py": py_module(rng, "src.core.validation", '''
def clamp(value, low, high):
    """Clamp value into [low, high]."""
    return max(low, min(high, value))
'''),
        "src/core/settings.py": py_module(rng, "src.core.settings", '''
import os

_LIMITS = os.path.join(os.path.dirname(__file__), "..", "..", "config", "limits.conf")


def limit(name):
    """Read config/limits.conf (key = value)."""
    with open(_LIMITS) as fh:
        for line in fh:
            line = line.split("#", 1)[0].strip()
            if line.startswith(name + " ") or line.startswith(name + "="):
                return int(line.split("=", 1)[1].strip())
    raise KeyError(name)
'''),
        "config/api.conf": "# API defaults\npage_size = 40\nsort = created_at\n",
        "config/limits.conf": "# hard limits enforced by validation\nmax_page_size = 25\nmax_body_kb = 512\n",
        "config/limits.conf.dist": "max_page_size = 20\n",
        "docs/pagination.md": "# Pagination\n\nList endpoints return **50** items per page unless `page_size` is given (maximum 200).\n\n" + paragraph(rng, 6) + "\n",
    }
    case = Case("docslarge-default-page-size", "docs-vs-code-large",
                "How many items does GET /items actually return per page when the request sends no page_size, once the configured default and the clamp are applied? "
                "Report back without changing any files.",
                [["25"]],
                "list_items falls back to DEFAULTS['page_size'], which src/api/defaults.py loads from config/api.conf (40, overriding the compiled-in 100), then clamps to "
                "limit('max_page_size') from config/limits.conf = 25. The docs' 50 and limits.conf.dist's 20 are not used.", 5,
                "Decoys: docs/pagination.md (50); config/api.conf (40); the compiled-in fallback (100); config/limits.conf.dist (20).",
                ["docs", "api", "pagination"])
    case.add("README.md", "# items-api\n\nFictional service. Documentation under docs/ is best effort; the code is authoritative.\n")
    build_tree(case, rng, specials)
    return case


def case_cli_exit_partial():
    rng = random.Random(20260955)
    specials = {
        "src/cli/sync.py": py_module(rng, "src.cli.sync", '''
def run(args):
    """Sync items; returns the exit status for the outcome."""
    from src.cli.exit_codes import status_for
    outcome = _sync(args)
    return status_for(outcome)


def _sync(args):
    failed = [a for a in args if a.startswith("bad:")]
    if not args:
        return "nothing"
    if failed and len(failed) < len(args):
        return "partial"
    return "failed" if failed else "ok"
'''),
        "src/cli/exit_codes.py": py_module(rng, "src.cli.exit_codes", '''
import importlib


def status_for(outcome):
    """Map an outcome name through the table named by exit_table in config/cli.conf."""
    from src.cli.compat import table_name
    table = importlib.import_module("src.cli.tables." + table_name())
    return table.CODES[outcome]
'''),
        "src/cli/compat.py": py_module(rng, "src.cli.compat", '''
import os

_CONF = os.path.join(os.path.dirname(__file__), "..", "..", "config", "cli.conf")


def table_name():
    """exit_table from config/cli.conf; `default` if unset."""
    with open(_CONF) as fh:
        for line in fh:
            line = line.split("#", 1)[0].strip()
            if line.startswith("exit_table"):
                return line.split("=", 1)[1].strip()
    return "default"
'''),
        "src/cli/tables/default.py": "CODES = {\"ok\": 0, \"nothing\": 0, \"partial\": 2, \"failed\": 1}\n",
        "src/cli/tables/strict.py": "CODES = {\"ok\": 0, \"nothing\": 3, \"partial\": 4, \"failed\": 1}\n",
        "src/cli/tables/lenient.py": "CODES = {\"ok\": 0, \"nothing\": 0, \"partial\": 0, \"failed\": 1}\n",
        "config/cli.conf": "# CLI settings\ncolor = auto\nexit_table = strict\n",
        "config/cli.conf.example": "exit_table = default\n",
        "docs/cli.md": "# CLI\n\n`sync` exits **2** when some items failed and the rest succeeded.\n\n" + paragraph(rng, 6) + "\n",
        "docs/sync.md": "# Sync\n\nExit statuses: 0 ok, 1 failed, 2 partial.\n\n" + paragraph(rng, 6) + "\n",
    }
    case = Case("docslarge-cli-exit-partial", "docs-vs-code-large",
                "What exit status does the `sync` CLI command actually return when some items fail and the rest succeed, once the configured exit table is applied? "
                "Report back without changing any files.",
                [["4"]],
                "sync.run maps the partial outcome through exit_codes.status_for, which loads the table named by exit_table in config/cli.conf: strict. "
                "src/cli/tables/strict.py sets partial = 4. The docs' 2 is the default table, lenient gives 0, and cli.conf.example selects default.", 5,
                "Decoys: docs/cli.md and docs/sync.md (2); src/cli/tables/default.py (2); src/cli/tables/lenient.py (0); config/cli.conf.example (default table).",
                ["docs", "cli", "exit-status"])
    case.add("README.md", "# sync-cli\n\nFictional tool. Documentation under docs/ is best effort; the code is authoritative.\n")
    build_tree(case, rng, specials)
    return case


def cases():
    return [case_duplicate_email_status(), case_rate_limit_header(), case_webhook_signature(), case_default_page_size(), case_cli_exit_partial()]
