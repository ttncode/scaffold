from flask import Blueprint, Response, jsonify

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
        return jsonify(status="unavailable", reason=str(error)), 503
