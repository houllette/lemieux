import json


class ApiError(Exception):
    pass


class InvalidEmail(ApiError):
    pass


class DuplicateEmail(ApiError):
    pass


# (status, error code) per exception type. The code is what clients branch on.
ERROR_CODES = {
    InvalidEmail: (400, "invalid_email"),
    DuplicateEmail: (409, "email_taken"),
}


def error_response(exc):
    status, code = ERROR_CODES.get(type(exc), (500, "internal"))
    return json.dumps({"error": code, "detail": str(exc)}), status
