"""Signer registry keyed by profile name."""

from src.webhooks.signers import v1, v2, none

SIGNERS = {"v1": v1, "v2": v2, "none": none, "hmac": v1}
