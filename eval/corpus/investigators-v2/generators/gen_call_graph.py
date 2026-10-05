"""call-graph-large: a 70-file fictional Python codebase where the real
implementation sits behind a registry table, a binding file and a resolved
class, with same-named decoys in legacy and sibling modules.
"""

from __future__ import annotations

import random

from common import Case, hex_id, paragraph, py_module, word, words

PACKAGES = {
    "app/core": ["container", "config", "clock", "errors", "logging_setup", "retry"],
    "app/models": ["order", "invoice", "customer", "ledger_entry", "snapshot", "quota"],
    "app/storage": ["journal", "legacy_journal", "ledger_writer", "blobs", "index", "migrations"],
    "app/services/audit": ["sink_v1", "sink_v2", "filters", "redaction"],
    "app/services/ledger": ["postings", "postings_legacy", "balances", "reconcile"],
    "app/services/quota": ["meter", "policy", "reset"],
    "app/hashing": ["fold64", "sha_like", "crc_fold", "registry"],
    "app/render": ["engine", "registry", "filters", "pdf_shim"],
    "app/notify": ["router", "templates", "backoff"],
    "app/notify/channels": ["pager", "pager_v2", "mail", "chat", "webhook"],
    "app/legacy": ["audit", "hashing", "renderers", "notify", "handlers"],
    "app/commands": ["export", "import_", "rollup", "reconcile", "prune", "status"],
    "app/handlers": ["refunds", "payments", "shipments", "cancellations"],
    "app/tasks": ["nightly", "hourly", "reconcile", "cleanup"],
    "app/http": ["routes", "controllers", "middleware", "responses"],
    "app/signals": ["dispatch", "registry", "quota_signals"],
    "app/events": ["bus", "subscriptions", "replay"],
    "app/scheduler": ["jobs", "cron", "leases"],
    "app/cli": ["main", "registry", "output"],
}


def build_codebase(case, rng, specials):
    """specials: {path: content} overrides; everything else is filler."""
    for pkg, mods in PACKAGES.items():
        init = "app/__init__.py" if False else pkg + "/__init__.py"
        if init not in specials:
            case.add(init, '"""%s package."""\n' % pkg.replace("/", "."))
        for mod in mods:
            path = "%s/%s.py" % (pkg, mod)
            if path not in specials:
                case.add(path, py_module(rng, path[:-3].replace("/", ".")))
    for path, content in specials.items():
        case.add(path, content)
    case.add("app/__init__.py", '"""application root"""\n')
    consts = ["\"\"\"Generated constants; do not edit by hand.\"\"\"", ""]
    for i in range(900):
        consts.append("%s_%s_%03d = %r  # %s" % (word(rng).upper(), word(rng).upper(), i, rng.choice([rng.randint(1, 10000), hex_id(rng, 12), word(rng)]), words(rng, 2)))
    case.add("app/generated/constants.py", "\n".join(consts) + "\n")
    case.add("app/generated/__init__.py", "")
    for i in range(20):
        case.add("tests/test_%s_%d.py" % (word(rng), i), "import pytest\n\nfrom app.%s import %s\n\n\n" % (rng.choice(["storage", "hashing", "render", "notify", "legacy"]), rng.choice(["journal", "sink_v1", "engine", "router", "audit"])) +
                 "\n\n".join("def test_%s_%d():\n    %s = %s\n    assert %s is not None" % (word(rng), n, word(rng), rng.choice(["{}", "[]", "0", "'x'"]), word(rng)) for n in range(6)) + "\n")
    for i in range(12):
        case.add("docs/modules/%s.md" % rng.choice(list(PACKAGES)).split("/")[-1] + ("-%d" % i), "# Notes\n\n" + "\n\n".join(paragraph(rng, 5) for _ in range(8)) + "\n")
    for i in range(6):
        case.add("docs/runbooks/%s-%d.md" % (word(rng), i), "# Runbook\n\n" + "\n\n".join("%d. %s" % (n + 1, paragraph(rng, 3)) for n in range(10)) + "\n")


CLI_MAIN = '''"""Command-line entry point.

Commands are not imported here: the registry maps a command name to a handler
key through config/commands.tsv, and the handler is resolved lazily.
"""

import sys

from app.cli.registry import lookup_handler
from app.cli.output import print_result


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        print_result({"error": "usage: lmxctl <command> [args]"})
        return 2
    name, *rest = argv
    handler = lookup_handler(name)
    if handler is None:
        print_result({"error": "unknown command %s" % name})
        return 2
    return handler(rest) or 0
'''

CLI_REGISTRY = '''"""Command registry.

The table in config/commands.tsv has two columns: the command name and the
handler key. Handler keys are dotted `module:function` references relative
to app.commands. The old hard-coded COMMANDS dict below is kept for the
`status` command only and is otherwise ignored by lookup_handler.
"""

import importlib
import os

_TABLE = os.path.join(os.path.dirname(__file__), "..", "..", "config", "commands.tsv")

COMMANDS = {
    "status": "status:show_status",
    "export": "export:export_legacy",   # superseded by the table; see config/commands.tsv
}


def _read_table():
    rows = {}
    with open(_TABLE) as fh:
        for line in fh:
            if not line.strip() or line.startswith("#"):
                continue
            name, key = line.rstrip("\\n").split("\\t")
            rows[name] = key
    return rows


def lookup_handler(name):
    if name == "status":
        key = COMMANDS[name]
    else:
        key = _read_table().get(name)
    if key is None:
        return None
    module, func = key.split(":")
    return getattr(importlib.import_module("app.commands." + module), func)
'''

CONTAINER = '''"""Service container.

`resolve(key)` reads config/bindings.conf, a flat `key = module:Class` file,
instantiates the class once and caches it. bindings.local.conf.example is a
template for developer overrides and is never read: only a file literally
named bindings.local.conf next to bindings.conf would be, and none exists.
"""

import importlib
import os

_CONF = os.path.join(os.path.dirname(__file__), "..", "..", "config", "bindings.conf")
_LOCAL = os.path.join(os.path.dirname(__file__), "..", "..", "config", "bindings.local.conf")
_cache = {}


def _bindings():
    out = {}
    for path in (_CONF, _LOCAL):
        if not os.path.exists(path):
            continue
        with open(path) as fh:
            for line in fh:
                line = line.split("#", 1)[0].strip()
                if "=" in line:
                    key, target = (part.strip() for part in line.split("=", 1))
                    out[key] = target
    return out


def resolve(key):
    if key not in _cache:
        target = _bindings()[key]
        module, cls = target.split(":")
        _cache[key] = getattr(importlib.import_module(module), cls)()
    return _cache[key]
'''


def bindings_conf(rng, real, decoy_local):
    lines = ["# Service bindings: key = module:Class. Read by app.core.container.resolve.", ""]
    keys = dict(real)
    for k in ["clock", "config", "blobs", "index", "mailer", "chat", "webhook", "quota", "balances", "pdf"]:
        keys.setdefault(k, "app.%s.%s:%s" % (rng.choice(["core", "storage", "notify", "services.quota", "render"]), word(rng), word(rng).capitalize() + "Service"))
    for k, v in keys.items():
        lines.append("%s = %s" % (k, v))
    lines.append("")
    lines.append("# Previous bindings, kept for reference:")
    for k, v in decoy_local.items():
        lines.append("# %s = %s" % (k, v))
    return "\n".join(lines) + "\n"


def docs_architecture(rng, claims):
    parts = ["# Architecture", "", "This page was written for the 2025 layout and has not been fully updated.", ""]
    for c in claims:
        parts.append(c)
        parts.append("")
        parts.append(paragraph(rng, 4))
        parts.append("")
    return "\n".join(parts) + "\n"


def case_cli_export_audit():
    rng = random.Random(20260921)
    real_fn, real_file = "append_record", "app/storage/journal.py"
    specials = {
        "app/cli/main.py": CLI_MAIN,
        "app/cli/registry.py": CLI_REGISTRY,
        "app/core/container.py": CONTAINER,
        "config/commands.tsv": "# command\thandler\nexport\texport:export_snapshot\nimport\timport_:import_bundle\nrollup\trollup:run_rollup\nreconcile\treconcile:run_reconcile\nprune\tprune:prune_old\n",
        "config/bindings.conf": bindings_conf(rng, {"audit": "app.services.audit.sink_v2:AuditSink", "ledger": "app.services.ledger.postings:LedgerClient"},
                                              {"audit": "app.services.audit.sink_v1:AuditSink", "ledger": "app.services.ledger.postings_legacy:LedgerClient"}),
        "config/bindings.local.conf.example": "# copy to bindings.local.conf to override\naudit = app.services.audit.sink_v1:AuditSink\n",
        "app/commands/export.py": py_module(rng, "app.commands.export", '''
def export_snapshot(args):
    """Export the current snapshot and leave an audit trail of the run."""
    from app.core.container import resolve
    audit = resolve("audit")
    snapshot = _build_snapshot(args)
    audit.record("export", snapshot["id"], rows=len(snapshot["rows"]))
    return 0


def export_legacy(args):
    """The pre-table export; still importable, no longer routed."""
    from app.legacy.audit import append_record
    append_record("export", args)
    return 0


def _build_snapshot(args):
    return {"id": "snap-" + "".join(args) or "snap-0", "rows": list(args)}
'''),
        "app/services/audit/sink_v2.py": py_module(rng, "app.services.audit.sink_v2", '''
class AuditSink:
    """Audit sink bound as `audit` in config/bindings.conf."""

    def __init__(self):
        from app.services.audit.redaction import scrub
        self._scrub = scrub

    def record(self, action, subject, **fields):
        from app.storage.journal import append_record
        entry = {"action": action, "subject": subject, **self._scrub(fields)}
        return append_record(entry)
'''),
        "app/services/audit/sink_v1.py": py_module(rng, "app.services.audit.sink_v1", '''
class AuditSink:
    """Previous audit sink; kept for replay tooling."""

    def record(self, action, subject, **fields):
        from app.storage.legacy_journal import write_record
        return write_record({"action": action, "subject": subject, **fields})
'''),
        "app/storage/journal.py": py_module(rng, "app.storage.journal", '''
def append_record(entry):
    """Append one audit entry to the active journal segment."""
    segment = _open_segment()
    segment.write(_encode(entry))
    segment.flush()
    return entry


def _open_segment():
    return open("/var/lib/app/journal/active.log", "a")


def _encode(entry):
    return repr(entry) + "\\n"
'''),
        "app/storage/legacy_journal.py": py_module(rng, "app.storage.legacy_journal", '''
def write_record(entry):
    """Legacy journal writer: fixed-width lines, no fsync."""
    with open("/var/lib/app/journal/legacy.log", "a") as fh:
        fh.write(str(entry) + "\\n")
    return entry


def append_record(entry):
    """Compatibility alias kept for old imports; delegates to write_record."""
    return write_record(entry)
'''),
        "app/legacy/audit.py": py_module(rng, "app.legacy.audit", '''
def append_record(action, args):
    """Legacy audit path used only by export_legacy."""
    from app.storage.legacy_journal import write_record
    return write_record({"action": action, "args": list(args)})
'''),
        "docs/architecture.md": docs_architecture(rng, ["## Audit\n\nCommands audit through `app.services.audit.sink_v1.AuditSink`, which writes with `write_record` in `app/storage/legacy_journal.py`.",
                                                       "## Commands\n\nThe CLI dispatches through the COMMANDS dict in `app/cli/registry.py`."]),
    }
    prompt = ("When `lmxctl export` is run through app/cli/main.py, which function ultimately appends the audit record to the journal, and which file "
              "defines that function? Follow the code as it is wired today. Report back without changing any files.")
    answer = ("main -> lookup_handler reads config/commands.tsv (export -> export:export_snapshot; the COMMANDS dict's export_legacy is bypassed) -> "
              "app/commands/export.py export_snapshot -> container.resolve('audit') -> config/bindings.conf binds audit to app.services.audit.sink_v2:AuditSink "
              "(the .example file is never read) -> AuditSink.record -> %s in %s. sink_v1's write_record/legacy_journal and app/legacy/audit.py's "
              "append_record are not on the path." % (real_fn, real_file))
    case = Case("callgraph-cli-export-audit-writer", "call-graph-large", prompt, [[real_fn], [real_file]], answer, 6,
                "Decoys: the COMMANDS dict routes export to export_legacy -> app/legacy/audit.py append_record -> legacy_journal.write_record; "
                "bindings.local.conf.example and docs/architecture.md bind audit to sink_v1 (write_record in app/storage/legacy_journal.py); "
                "legacy_journal.py also defines an append_record alias.", ["callgraph", "python", "cli"])
    case.add("README.md", "# lmxctl\n\nA fictional operations CLI. Start at app/cli/main.py. Configuration tables live under config/.\n")
    build_codebase(case, rng, specials)
    return case


def case_event_refund_handler():
    rng = random.Random(20260922)
    real_fn, real_file = "post_adjustment", "app/storage/ledger_writer.py"
    specials = {
        "app/core/container.py": CONTAINER,
        "app/events/bus.py": py_module(rng, "app.events.bus", '''
def publish(event, payload):
    """Deliver an event to the handler named for it in config/subscriptions.tsv."""
    from app.events.subscriptions import handler_for
    handler = handler_for(event)
    if handler is None:
        raise LookupError(event)
    return handler(payload)
'''),
        "app/events/subscriptions.py": py_module(rng, "app.events.subscriptions", '''
import os

_TABLE = os.path.join(os.path.dirname(__file__), "..", "..", "config", "subscriptions.tsv")


def handler_for(event):
    """Map an event name to a handler through the table and the HANDLERS registry."""
    from app.handlers import HANDLERS
    with open(_TABLE) as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            name, key = line.rstrip("\\n").split("\\t")
            if name == event:
                return HANDLERS[key]
    return None
'''),
        "config/subscriptions.tsv": "# event\thandler key\norder.paid\tpayment_v1\norder.refunded\trefund_v3\norder.shipped\tshipment_v1\norder.cancelled\tcancel_v2\norder.refund_requested\trefund_v1\n",
        "app/handlers/__init__.py": '''"""Handler registry keyed by the names config/subscriptions.tsv uses."""

from app.handlers import refunds, payments, shipments, cancellations

HANDLERS = {
    "payment_v1": payments.on_payment,
    "refund_v1": refunds.on_refund,
    "refund_v2": refunds.on_refund_v2,
    "refund_v3": refunds.on_refund_v3,
    "shipment_v1": shipments.on_shipment,
    "cancel_v2": cancellations.on_cancel,
}
''',
        "app/handlers/refunds.py": py_module(rng, "app.handlers.refunds", '''
def on_refund(payload):
    """First refund handler: records the request only, posts nothing."""
    from app.legacy.handlers import note_refund
    return note_refund(payload)


def on_refund_v2(payload):
    """Second handler; posted through the legacy postings client."""
    from app.services.ledger.postings_legacy import LedgerClient
    return LedgerClient().adjust(payload["order_id"], -payload["amount"])


def on_refund_v3(payload):
    """Current handler: resolves the bound ledger client and posts the adjustment."""
    from app.core.container import resolve
    ledger = resolve("ledger")
    return ledger.adjust(payload["order_id"], -payload["amount"], reason="refund")
'''),
        "config/bindings.conf": bindings_conf(rng, {"ledger": "app.services.ledger.postings:LedgerClient", "audit": "app.services.audit.sink_v2:AuditSink"},
                                              {"ledger": "app.services.ledger.postings_legacy:LedgerClient"}),
        "app/services/ledger/postings.py": py_module(rng, "app.services.ledger.postings", '''
class LedgerClient:
    """Ledger client bound as `ledger`."""

    def adjust(self, order_id, amount, reason=None):
        from app.storage.ledger_writer import post_adjustment
        return post_adjustment(order_id, amount, reason or "adjustment")

    def balance(self, order_id):
        from app.services.ledger.balances import current
        return current(order_id)
'''),
        "app/services/ledger/postings_legacy.py": py_module(rng, "app.services.ledger.postings_legacy", '''
class LedgerClient:
    """Pre-2026 ledger client; writes through the legacy posting path."""

    def adjust(self, order_id, amount, reason=None):
        from app.storage.ledger_writer import post_legacy
        return post_legacy(order_id, amount)
'''),
        "app/storage/ledger_writer.py": py_module(rng, "app.storage.ledger_writer", '''
def post_adjustment(order_id, amount, reason):
    """Write a signed adjustment line to the ledger."""
    line = {"order": order_id, "amount": amount, "reason": reason}
    _append(line)
    return line


def post_legacy(order_id, amount):
    """Legacy posting: no reason column."""
    _append({"order": order_id, "amount": amount})


def _append(line):
    with open("/var/lib/app/ledger/postings.log", "a") as fh:
        fh.write(repr(line) + "\\n")
'''),
        "app/legacy/handlers.py": py_module(rng, "app.legacy.handlers", '''
def note_refund(payload):
    """Record that a refund was requested; does not touch the ledger."""
    return {"noted": payload.get("order_id")}


def post_adjustment(order_id, amount):
    """Old name for the legacy posting path; unused."""
    from app.storage.ledger_writer import post_legacy
    return post_legacy(order_id, amount)
'''),
        "docs/architecture.md": docs_architecture(rng, ["## Events\n\n`order.refunded` is handled by `on_refund` in `app/handlers/refunds.py`, which posts through `app.services.ledger.postings_legacy`.",
                                                       "## Ledger\n\nAll ledger writes go through `post_legacy`."]),
    }
    prompt = ("When the event bus publishes `order.refunded`, which function actually writes the ledger adjustment for that refund, and which file "
              "defines it? Follow the subscriptions table and the service bindings as they stand. Report back without changing any files.")
    answer = ("bus.publish -> subscriptions.handler_for reads config/subscriptions.tsv (order.refunded -> refund_v3; refund_v1 is for order.refund_requested) -> "
              "HANDLERS['refund_v3'] = refunds.on_refund_v3 -> container.resolve('ledger') -> config/bindings.conf binds ledger to "
              "app.services.ledger.postings:LedgerClient -> adjust -> %s in %s. on_refund (note_refund), on_refund_v2 (postings_legacy -> post_legacy) and "
              "app/legacy/handlers.py's post_adjustment are not on the path." % (real_fn, real_file))
    case = Case("callgraph-event-refund-writer", "call-graph-large", prompt, [[real_fn], [real_file]], answer, 7,
                "Decoys: on_refund -> app/legacy/handlers.py note_refund (docs say this); on_refund_v2 -> postings_legacy -> post_legacy; "
                "app/legacy/handlers.py has its own post_adjustment; the commented previous binding maps ledger to postings_legacy.", ["callgraph", "python", "events"])
    case.add("README.md", "# order-events\n\nA fictional event-driven order service. Events enter through app/events/bus.py.\n")
    build_codebase(case, rng, specials)
    return case


def case_http_route_template():
    rng = random.Random(20260923)
    real_file = "templates/pdf/invoice-2026.tpl"
    specials = {
        "app/core/container.py": CONTAINER,
        "app/http/routes.py": py_module(rng, "app.http.routes", '''
ROUTES = [
    ("GET", "/invoices/{id}", "controllers:show_invoice"),
    ("GET", "/invoices/{id}.pdf", "controllers:invoice_document"),
    ("GET", "/invoices/{id}/print", "controllers:invoice_print"),
    ("GET", "/orders/{id}", "controllers:show_order"),
    ("POST", "/orders", "controllers:create_order"),
]


def dispatch(method, path):
    """Match a route and return the controller callable."""
    import importlib
    for m, pattern, target in ROUTES:
        if m == method and _matches(pattern, path):
            module, func = target.split(":")
            return getattr(importlib.import_module("app.http." + module), func)
    return None


def _matches(pattern, path):
    return pattern.split("/")[1] == path.split("/")[1]
'''),
        "app/http/controllers.py": py_module(rng, "app.http.controllers", '''
def show_invoice(request):
    """HTML invoice page."""
    from app.render.engine import render
    return render("invoice_page", request.invoice)


def invoice_document(request):
    """The downloadable invoice: rendered with the document template key."""
    from app.render.engine import render
    return render("invoice_document", request.invoice, media="pdf")


def invoice_print(request):
    """Print stylesheet variant."""
    from app.render.engine import render
    return render("invoice_print", request.invoice)
'''),
        "app/render/engine.py": py_module(rng, "app.render.engine", '''
def render(key, model, media="html"):
    """Render `model` with the template file that config/templates.tsv maps `key` to for `media`."""
    from app.render.registry import template_path
    path = template_path(key, media)
    with open(path) as fh:
        source = fh.read()
    return _fill(source, model)


def _fill(source, model):
    return source
'''),
        "app/render/registry.py": py_module(rng, "app.render.registry", '''
import os

_TABLE = os.path.join(os.path.dirname(__file__), "..", "..", "config", "templates.tsv")
_ROOT = os.path.join(os.path.dirname(__file__), "..", "..", "templates")


def template_path(key, media):
    """Look up `key` for `media` in the table; a row's media column may be `*`.

    The most specific row wins: an exact media match beats a `*` row.
    """
    exact, wildcard = None, None
    with open(_TABLE) as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            k, m, rel = line.rstrip("\\n").split("\\t")
            if k != key:
                continue
            if m == media:
                exact = rel
            elif m == "*":
                wildcard = rel
    rel = exact or wildcard
    if rel is None:
        raise KeyError(key)
    return os.path.join(_ROOT, rel)
'''),
        "config/templates.tsv": "# key\tmedia\tfile (relative to templates/)\ninvoice_page\thtml\thtml/invoice.html\ninvoice_document\t*\thtml/invoice-document.html\ninvoice_document\tpdf\tpdf/invoice-2026.tpl\ninvoice_print\thtml\thtml/invoice-print.html\norder_page\thtml\thtml/order.html\nreceipt\tpdf\tpdf/receipt.tpl\n",
        "templates/html/invoice.html": "<html><body><h1>Invoice {{ id }}</h1>%s</body></html>\n" % paragraph(rng, 3),
        "templates/html/invoice-document.html": "<html><body><h1>Invoice document {{ id }}</h1>%s</body></html>\n" % paragraph(rng, 3),
        "templates/html/invoice-print.html": "<html><body class=print><h1>Invoice {{ id }}</h1>%s</body></html>\n" % paragraph(rng, 3),
        "templates/html/order.html": "<html><body><h1>Order {{ id }}</h1></body></html>\n",
        "templates/pdf/invoice-2026.tpl": "%% invoice document layout, 2026 revision\n%s\n" % paragraph(rng, 4),
        "templates/pdf/invoice.tpl": "%% previous invoice document layout; not referenced by the table\n%s\n" % paragraph(rng, 4),
        "templates/pdf/receipt.tpl": "%% receipt\n",
        "templates/legacy/invoice_pdf.tpl": "%% used by app/legacy/renderers.py only\n%s\n" % paragraph(rng, 3),
        "app/legacy/renderers.py": py_module(rng, "app.legacy.renderers", '''
def render_invoice_pdf(invoice):
    """Old direct renderer, still called by the replay tool."""
    with open("templates/legacy/invoice_pdf.tpl") as fh:
        return fh.read()
'''),
        "docs/architecture.md": docs_architecture(rng, ["## Documents\n\nThe PDF invoice is rendered from `templates/pdf/invoice.tpl` by `app/legacy/renderers.py`.",
                                                       "## Templates\n\nTemplate keys map one-to-one to files under templates/html/."]),
    }
    prompt = ("Which template file (path relative to the repository root) is rendered for GET /invoices/{id}.pdf once the route table, the controller and the "
              "template registry are followed? Report back without changing any files.")
    answer = ("routes.py maps GET /invoices/{id}.pdf to controllers.invoice_document, which calls render('invoice_document', ..., media='pdf'). registry.template_path "
              "prefers the exact media row in config/templates.tsv over the `*` row, so the file is %s, not html/invoice-document.html; templates/pdf/invoice.tpl and "
              "templates/legacy/invoice_pdf.tpl are unreferenced by the table." % real_file)
    case = Case("callgraph-http-invoice-template", "call-graph-large", prompt, [["pdf/invoice-2026.tpl"]], answer, 6,
                "Decoys: the `*` row (templates/html/invoice-document.html); templates/pdf/invoice.tpl (old, unreferenced); templates/legacy/invoice_pdf.tpl via "
                "app/legacy/renderers.py and docs/architecture.md; the /invoices/{id} html route (templates/html/invoice.html).", ["callgraph", "python", "http"])
    case.add("README.md", "# invoicing\n\nA fictional HTTP service. Routes are declared in app/http/routes.py; templates live under templates/.\n")
    build_codebase(case, rng, specials)
    return case


def case_scheduler_job_hasher():
    rng = random.Random(20260924)
    real_fn, real_file = "digest_fold64", "app/hashing/fold64.py"
    specials = {
        "app/core/container.py": CONTAINER,
        "app/scheduler/jobs.py": py_module(rng, "app.scheduler.jobs", '''
import os

_TABLE = os.path.join(os.path.dirname(__file__), "..", "..", "config", "schedule.tsv")


def run(job_name):
    """Run a named job: the table maps names to `module:function` under app.tasks."""
    import importlib
    with open(_TABLE) as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            name, when, target = line.rstrip("\\n").split("\\t")
            if name == job_name:
                module, func = target.split(":")
                return getattr(importlib.import_module("app.tasks." + module), func)()
    raise LookupError(job_name)
'''),
        "config/schedule.tsv": "# job\twhen\ttask\nnightly-rollup\t02:00\tnightly:rollup\nreconcile\t03:30\treconcile:run_nightly_reconcile\nreconcile-dry\t03:00\treconcile:run_dry\ncleanup\t04:00\tcleanup:sweep\n",
        "app/tasks/reconcile.py": py_module(rng, "app.tasks.reconcile", '''
def run_nightly_reconcile():
    """Reconcile balances and store a digest of the reconciled set."""
    from app.hashing import default_algorithm
    from app.services.ledger.reconcile import reconciled_rows
    rows = reconciled_rows()
    digest = default_algorithm()(rows)
    _store(digest)
    return digest


def run_dry():
    """Dry run: hashes with the fixed legacy algorithm for comparison output."""
    from app.hashing.sha_like import digest_sha_like
    from app.services.ledger.reconcile import reconciled_rows
    return digest_sha_like(reconciled_rows())


def _store(digest):
    with open("/var/lib/app/reconcile/digest", "w") as fh:
        fh.write(digest)
'''),
        "app/hashing/__init__.py": '''"""Hashing algorithms and the configured default.

`default_algorithm()` reads `hash_algorithm` from config/settings.conf and
returns the callable registered under that name in ALGORITHMS.
"""

from app.hashing.fold64 import digest_fold64
from app.hashing.sha_like import digest_sha_like
from app.hashing.crc_fold import digest_crc_fold

ALGORITHMS = {
    "fold64": digest_fold64,
    "sha-like": digest_sha_like,
    "crc-fold": digest_crc_fold,
    "legacy": digest_crc_fold,
}


def default_algorithm():
    from app.core.config import setting
    return ALGORITHMS[setting("hash_algorithm")]
''',
        "app/core/config.py": py_module(rng, "app.core.config", '''
import os

_SETTINGS = os.path.join(os.path.dirname(__file__), "..", "..", "config", "settings.conf")


def setting(name):
    """Read one key from config/settings.conf; the last occurrence wins."""
    value = None
    with open(_SETTINGS) as fh:
        for line in fh:
            line = line.split("#", 1)[0].strip()
            if line.startswith(name + " ") or line.startswith(name + "="):
                value = line.split("=", 1)[1].strip()
    return value
'''),
        "config/settings.conf": "# application settings; app.core.config.setting reads these, last occurrence wins\nhash_algorithm = sha-like\nrollup_window = 24h\ncleanup_keep_days = 30\n%s\n# overrides appended by the 2026-05 migration\nhash_algorithm = fold64\n" % "\n".join("%s = %s" % (word(rng), word(rng)) for _ in range(20)),
        "config/settings.example.conf": "hash_algorithm = crc-fold\n",
        "app/hashing/fold64.py": py_module(rng, "app.hashing.fold64", '''
def digest_fold64(rows):
    """Fold every row into a 64-bit accumulator and render it as hex."""
    acc = 0
    for row in rows:
        acc = (acc * 1099511628211 + hash(repr(row))) & 0xFFFFFFFFFFFFFFFF
    return "%016x" % acc
'''),
        "app/hashing/sha_like.py": py_module(rng, "app.hashing.sha_like", '''
def digest_sha_like(rows):
    """Fixed-width digest used by dry runs and by the previous default."""
    return "".join("%02x" % (hash(repr(r)) & 0xFF) for r in rows)[:64]
'''),
        "app/hashing/crc_fold.py": py_module(rng, "app.hashing.crc_fold", '''
def digest_crc_fold(rows):
    """CRC-based fold kept for `legacy` digests."""
    return "%08x" % (sum(hash(repr(r)) for r in rows) & 0xFFFFFFFF)
'''),
        "app/legacy/hashing.py": py_module(rng, "app.legacy.hashing", '''
def digest_fold64(rows):
    """Older fold64 with a 32-bit accumulator; superseded by app.hashing.fold64."""
    return "%08x" % (sum(hash(repr(r)) for r in rows) & 0xFFFFFFFF)
'''),
        "docs/architecture.md": docs_architecture(rng, ["## Digests\n\nThe reconcile job stores a `sha-like` digest (see `hash_algorithm` at the top of config/settings.conf).",
                                                       "## Scheduler\n\nJobs are wired in app/scheduler/cron.py."]),
    }
    prompt = ("When the scheduler runs the `reconcile` job, which function computes the digest that the job stores, and which file defines it? "
              "Follow the schedule table, the task and the configured algorithm. Report back without changing any files.")
    answer = ("schedule.tsv maps reconcile to reconcile:run_nightly_reconcile (reconcile-dry is a different job using digest_sha_like). It calls "
              "app.hashing.default_algorithm(), which reads hash_algorithm from config/settings.conf where the last occurrence wins: fold64 (the first line says "
              "sha-like, settings.example.conf says crc-fold). ALGORITHMS['fold64'] is %s in %s; app/legacy/hashing.py's same-named function is superseded." % (real_fn, real_file))
    case = Case("callgraph-scheduler-reconcile-digest", "call-graph-large", prompt, [[real_fn], [real_file]], answer, 7,
                "Decoys: the first hash_algorithm line (sha-like -> app/hashing/sha_like.py digest_sha_like, also what docs say); settings.example.conf (crc-fold); "
                "reconcile-dry's run_dry; app/legacy/hashing.py defines its own digest_fold64.", ["callgraph", "python", "scheduler"])
    case.add("README.md", "# nightly\n\nA fictional batch service. Jobs are started by app/scheduler/jobs.py.\n")
    build_codebase(case, rng, specials)
    return case


def case_signal_notifier_channel():
    rng = random.Random(20260925)
    real_fn, real_file = "deliver_page", "app/notify/channels/pager_v2.py"
    specials = {
        "app/core/container.py": CONTAINER,
        "app/signals/dispatch.py": py_module(rng, "app.signals.dispatch", '''
import os

_TABLE = os.path.join(os.path.dirname(__file__), "..", "..", "config", "signals.tsv")


def fire(signal, **fields):
    """Route a signal to the notifier key named in config/signals.tsv."""
    from app.notify.router import notify
    with open(_TABLE) as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            name, key = line.rstrip("\\n").split("\\t")
            if name == signal:
                return notify(key, fields)
    return None
'''),
        "config/signals.tsv": "# signal\tnotifier key\nquota.exceeded\tquota-critical\nquota.warning\tquota-soft\nbackup.failed\tops\nexport.finished\tdigest\n",
        "app/notify/router.py": py_module(rng, "app.notify.router", '''
import os

_CHANNELS = os.path.join(os.path.dirname(__file__), "..", "..", "config", "channels.conf")


def notify(key, fields):
    """Send through the channel that config/channels.conf assigns to `key`.

    The file has `[key] channel = <name>` blocks; a `[default]` block is
    used when a key has no block of its own.
    """
    channel = _channel_for(key)
    import importlib
    mod = importlib.import_module("app.notify.channels." + channel)
    return mod.deliver(key, fields)


def _channel_for(key):
    current, chosen, default = None, None, None
    with open(_CHANNELS) as fh:
        for line in fh:
            line = line.split("#", 1)[0].strip()
            if line.startswith("[") and line.endswith("]"):
                current = line[1:-1]
            elif line.startswith("channel") and "=" in line:
                value = line.split("=", 1)[1].strip()
                if current == key:
                    chosen = value
                elif current == "default":
                    default = value
    return chosen or default
'''),
        "config/channels.conf": "# notifier key -> channel module under app/notify/channels\n[default]\nchannel = mail\n\n[quota-soft]\nchannel = chat\n\n[ops]\nchannel = pager\n\n[quota-critical]\nchannel = pager_v2\n\n[digest]\nchannel = mail\n",
        "config/channels.conf.orig": "[default]\nchannel = mail\n\n[quota-critical]\nchannel = pager\n",
        "app/notify/channels/pager.py": py_module(rng, "app.notify.channels.pager", '''
def deliver(key, fields):
    """Original pager channel."""
    return deliver_page(key, fields, endpoint="pager.example.test")


def deliver_page(key, fields, endpoint):
    """Send a page over the v1 endpoint."""
    return {"sent": key, "via": endpoint}
'''),
        "app/notify/channels/pager_v2.py": py_module(rng, "app.notify.channels.pager_v2", '''
def deliver(key, fields):
    """Pager channel, v2 endpoint with acknowledgement tracking."""
    from app.notify.backoff import with_backoff
    return with_backoff(lambda: deliver_page(key, fields))


def deliver_page(key, fields):
    """Send a page over the v2 endpoint and wait for the ack."""
    return {"sent": key, "via": "pager-v2.example.test", "ack": True}
'''),
        "app/notify/channels/mail.py": py_module(rng, "app.notify.channels.mail", '''
def deliver(key, fields):
    """Mail channel."""
    return send_mail(key, fields)


def send_mail(key, fields):
    return {"mailed": key}
'''),
        "app/notify/channels/chat.py": py_module(rng, "app.notify.channels.chat", '''
def deliver(key, fields):
    return post_message(key, fields)


def post_message(key, fields):
    return {"posted": key}
'''),
        "app/legacy/notify.py": py_module(rng, "app.legacy.notify", '''
def deliver_page(key, fields):
    """Legacy pager delivery; only the replay tool calls this."""
    return {"sent": key, "via": "legacy"}
'''),
        "docs/architecture.md": docs_architecture(rng, ["## Signals\n\n`quota.exceeded` pages through `app/notify/channels/pager.py` (`deliver_page`).",
                                                       "## Channels\n\nEvery notifier key falls through to the [default] mail channel unless the router is patched."]),
    }
    prompt = ("When the `quota.exceeded` signal fires through app/signals/dispatch.py, which function actually delivers the page, and which file defines it? "
              "Follow the signal table, the router and the channel configuration. Report back without changing any files.")
    answer = ("dispatch.fire maps quota.exceeded to key quota-critical (config/signals.tsv); router._channel_for finds the [quota-critical] block in "
              "config/channels.conf (channel = pager_v2; channels.conf.orig's pager and the [default] mail block do not apply), imports "
              "app.notify.channels.pager_v2 and calls deliver, which wraps %s defined in %s. pager.py's deliver_page and app/legacy/notify.py's "
              "deliver_page are decoys." % (real_fn, real_file))
    case = Case("callgraph-signal-quota-pager", "call-graph-large", prompt, [[real_fn], [real_file]], answer, 6,
                "Decoys: app/notify/channels/pager.py deliver_page (docs and channels.conf.orig point here); app/legacy/notify.py deliver_page; "
                "the [default] mail channel (send_mail); quota.warning's chat channel.", ["callgraph", "python", "signals"])
    case.add("README.md", "# alerting\n\nA fictional notification service. Signals enter through app/signals/dispatch.py.\n")
    build_codebase(case, rng, specials)
    return case


def cases():
    return [case_cli_export_audit(), case_event_refund_handler(), case_http_route_template(), case_scheduler_job_hasher(), case_signal_notifier_channel()]
