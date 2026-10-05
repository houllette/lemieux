class ValidationError(Exception):
    pass


REQUIRED = ("id", "sku", "quantity")


def validate_order(payload):
    for field in REQUIRED:
        if field not in payload:
            raise ValidationError(f"missing field: {field}")
    if payload["quantity"] <= 0:
        raise ValidationError("quantity must be positive")
    return payload
