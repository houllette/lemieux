from api.pagination import page_size
from api.repo import repo


def list_items(request):
    size = page_size(request)
    return {"items": repo.first(size), "page_size": size}, 200
