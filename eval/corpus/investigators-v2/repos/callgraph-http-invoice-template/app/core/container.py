"""Service container.

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
