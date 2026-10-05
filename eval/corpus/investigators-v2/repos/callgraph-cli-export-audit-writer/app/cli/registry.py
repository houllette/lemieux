"""Command registry.

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
            name, key = line.rstrip("\n").split("\t")
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
