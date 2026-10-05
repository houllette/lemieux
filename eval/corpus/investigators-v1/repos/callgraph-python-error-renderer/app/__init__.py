from app.errors import register_error_handlers
from app.framework import App
from app.routes.health import bp as health_bp
from app.routes.orders import bp as orders_bp


def create_app():
    app = App(__name__)
    app.register_blueprint(health_bp)
    app.register_blueprint(orders_bp)
    register_error_handlers(app)
    return app
