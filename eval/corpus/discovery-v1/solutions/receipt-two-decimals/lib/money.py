"""Money helpers. Amounts are integer cents; never floats."""


def format_cents(cents):
    """Render integer cents as a dollar string: 1250 -> "12.50"."""
    return "%d.%02d" % divmod(cents, 100)
