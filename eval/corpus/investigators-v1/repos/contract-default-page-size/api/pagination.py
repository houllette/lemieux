from api import settings


def page_size(request):
    raw = request.args.get("page_size")
    if raw is None:
        return settings.DEFAULT_PAGE_SIZE
    return max(1, min(int(raw), settings.MAX_PAGE_SIZE))
