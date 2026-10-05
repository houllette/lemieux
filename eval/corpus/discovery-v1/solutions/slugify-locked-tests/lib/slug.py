"""URL slugs for article titles."""

import re
import unicodedata


def slugify(title):
    """Turn a title into a lower-case, hyphen-separated URL slug."""
    ascii_title = unicodedata.normalize("NFKD", title).encode("ascii", "ignore").decode("ascii")
    slug = re.sub(r"[^a-z0-9]+", "-", ascii_title.lower())
    return slug.strip("-")
