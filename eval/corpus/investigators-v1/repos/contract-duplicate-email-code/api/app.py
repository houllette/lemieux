from api.errors import ApiError, error_response
from api.users import create_user


class App:
    def __init__(self):
        self.routes = {("POST", "/users"): create_user}

    def handle(self, method, path, payload):
        try:
            return self.routes[(method, path)](payload)
        except ApiError as exc:
            return error_response(exc)
