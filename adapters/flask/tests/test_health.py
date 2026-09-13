from app import create_app


def test_live_reports_ok() -> None:
    response = create_app().test_client().get("/health/live")
    assert response.status_code == 200
    assert response.get_json() == {"status": "ok"}


def test_ready_route_is_registered() -> None:
    rules = create_app().url_map.iter_rules()
    assert any(rule.rule == "/health/ready" for rule in rules)
