"""Hashing algorithms and the configured default.

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
