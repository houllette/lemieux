import tomllib

from api import constants

with open("config/limits.toml", "rb") as fh:
    _limits = tomllib.load(fh)

# Configuration may lower the page sizes but never exceed the hard ceilings.
DEFAULT_PAGE_SIZE = min(_limits["pagination"]["default"], constants.HARD_MAX_PAGE_SIZE)
MAX_PAGE_SIZE = min(_limits["pagination"]["max"], constants.HARD_MAX_PAGE_SIZE)
MAX_UPLOAD_BYTES = min(_limits["uploads"]["max_bytes"], constants.HARD_MAX_UPLOAD_BYTES)
