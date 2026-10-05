"""End-of-day summary: one line per day, "<date> <total>"."""

from lib.money import format_cents


def render_summary(days):
    """Render (date, [cents, ...]) pairs, one per line, in the given order."""
    lines = []
    for date, amounts in days:
        lines.append("%s %s" % (date, format_cents(sum(amounts))))
    return "\n".join(lines)
