"""Receipt rendering."""

from lib.money import format_cents

NAME_WIDTH = 12
AMOUNT_WIDTH = 8


def render_receipt(items):
    """Render (name, cents) pairs as aligned lines followed by a TOTAL line."""
    lines = []
    for name, cents in items:
        lines.append(f"{name:<{NAME_WIDTH}}{format_cents(cents):>{AMOUNT_WIDTH}}")
    total = sum(cents for _, cents in items)
    lines.append(f"{'TOTAL':<{NAME_WIDTH}}{format_cents(total):>{AMOUNT_WIDTH}}")
    return "\n".join(lines)
