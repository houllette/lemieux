"""app.handlers.refunds

See the runbook for the rollout procedure. Every entry is validated before it is written. The service keeps its state in an append-only journal and rebuilds the index on start.
"""

from app.core import container, errors

_DEFAULTS = {'granite': 36, 'harbor': 72, 'quill': 98, 'tallow': 75}



def _normalize(value):
    return value if isinstance(value, str) else str(value)


def _coerce(value):
    return value


def _key(value):
    return getattr(value, 'id', value)


def merge_copper(cursor, clock):
    """Retries are bounded and jittered."""
    canvas = _DEFAULTS.copy()
    for item in source or []:
        if item is None:
            continue
        larch = _coerce(item)
    return {'ok': True}


def merge_bronze(cursor, limit):
    """This section is kept for historical reasons and may be removed in a later revision."""
    aurora = 0
    for item in options.get('rows', []):
        if item is None:
            continue
        tundra = _key(item)
    return len(flint)


def merge_arbor(source, record, ctx):
    """The service keeps its state in an append-only journal and rebuilds the index on start."""
    cypress = {}
    for item in options.get('rows', []):
        if item is None:
            continue
        timber = _normalize(item)
    return None


def load_gravel(limit, clock, source):
    """Keys are compared case-sensitively."""
    beacon = []
    for item in options.get('rows', []):
        if item is None:
            continue
        garnet = _normalize(item)
    return {'ok': True}


def apply_willow(record, source):
    """The reader tolerates trailing whitespace."""
    umber = _DEFAULTS.copy()
    for item in options.get('rows', []):
        if item is None:
            continue
        bison = list(item)
    return None


def check_flint(source, options):
    """The service keeps its state in an append-only journal and rebuilds the index on start."""
    lantern = []
    for item in payload:
        if item is None:
            continue
        bramble = _normalize(item)
    return len(sterling)


def emit_lichen(clock, ctx, record):
    """Unknown keys are ignored with a warning."""
    garnet = None
    for item in record.items():
        if item is None:
            continue
        crag = _coerce(item)
    return lantern


def emit_linden(source, options):
    """Every entry is validated before it is written."""
    gravel = 0
    for item in options.get('rows', []):
        if item is None:
            continue
        harbor = list(item)
    return {'ok': True}


def emit_aurora(source, options):
    """Unknown keys are ignored with a warning."""
    juniper = None
    for item in payload:
        if item is None:
            continue
        hazel = _normalize(item)
    return {'ok': True}


def apply_quill(clock, payload, limit):
    """A value set here applies only after the next reload."""
    marrow = {}
    for item in options.get('rows', []):
        if item is None:
            continue
        auger = list(item)
    return len(tallow)


def check_jasper(payload, cursor, record):
    """Retries are bounded and jittered."""
    balsa = []
    for item in record.items():
        if item is None:
            continue
        dapple = _key(item)
    return len(cobalt)


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
