from app.framework import Blueprint

bp = Blueprint("health")


@bp.get("/health")
def health():
    return {"status": "ok"}, 200
