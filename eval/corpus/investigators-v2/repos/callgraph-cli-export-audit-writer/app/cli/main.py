"""Command-line entry point.

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
