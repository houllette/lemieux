"""URL slugs for article titles."""

import re


def slugify(title):
    """Turn a title into a lower-case, hyphen-separated URL slug."""
    slug = title.lower().replace(" ", "-")
    slug = re.sub(r"[^a-z0-9-]", "", slug)
    return slug
