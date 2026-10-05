class Blueprint:
    def __init__(self, name):
        self.name = name
        self.routes = []

    def post(self, path):
        def decorator(fn):
            self.routes.append(("POST", path, fn))
            return fn

        return decorator

    def get(self, path):
        def decorator(fn):
            self.routes.append(("GET", path, fn))
            return fn

        return decorator


class App:
    def __init__(self, name):
        self.name = name
        self.blueprints = []
        self.error_handlers = {}

    def register_blueprint(self, bp):
        self.blueprints.append(bp)

    def register_error_handler(self, exc_type, handler):
        self.error_handlers[exc_type] = handler

    def dispatch_error(self, exc):
        for exc_type in type(exc).__mro__:
            handler = self.error_handlers.get(exc_type)
            if handler is not None:
                return handler(exc)
        raise exc
