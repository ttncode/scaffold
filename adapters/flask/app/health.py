from flask import Blueprint, Response, current_app, jsonify

# @DB_ENGINE@

health = Blueprint("health", __name__)

Reply = Response | tuple[Response, int]


@health.get("/health/live")
def live() -> Reply:
    return jsonify(status="ok")


@health.get("/health/ready")
def ready() -> Reply:
    try:
        # @DB_PROBE@
        raise RuntimeError("no database is configured for this project")
    except Exception as error:  # noqa: BLE001
        # Logged, not returned: the error names host and user, and this route is
        # unauthenticated.
        current_app.logger.warning("readiness probe failed: %s", error)
        return jsonify(status="unavailable"), 503
