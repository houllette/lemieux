"""End-of-day summary: one line per day, "<date> <total>"."""


def render_summary(days):
    """Render (date, [cents, ...]) pairs, one per line, in the given order."""
    lines = []
    for date, amounts in days:
        total = sum(amounts)
        dollars = round(total / 100, 2)
        lines.append("%s %s" % (date, dollars))
    return "\n".join(lines)
