import json

from app.validation import ValidationError


class OrderError(Exception):
    pass


def render_validation_error(exc):
    body = {"error": "validation_failed", "detail": str(exc)}
    return json.dumps(body), 400


def render_order_error(exc):
    body = {"error": "order_rejected", "detail": str(exc)}
    return json.dumps(body), 422


def register_error_handlers(app):
    app.register_error_handler(ValidationError, render_validation_error)
    app.register_error_handler(OrderError, render_order_error)
