from app.errors import OrderError
from app.framework import Blueprint
from app.validation import ValidationError, validate_order

bp = Blueprint("orders")


@bp.post("/orders")
def create_order(payload):
    try:
        order = validate_order(payload)
    except ValidationError as exc:
        # Surface validation problems as order errors so clients get one shape.
        raise OrderError(str(exc)) from exc
    return {"id": order["id"]}, 201
