from fastapi.testclient import TestClient

from app.main import app


client = TestClient(app)


def test_healthz_returns_ok():
    response = client.get("/healthz")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_readyz_returns_ready():
    response = client.get("/readyz")

    assert response.status_code == 200
    assert response.json() == {"status": "ready"}


def test_metrics_exposes_prometheus_payload():
    client.get("/healthz")

    response = client.get("/metrics")

    assert response.status_code == 200
    assert "reservation_api_http_requests_total" in response.text


def test_reservation_timeout_is_visible_to_clients(monkeypatch):
    monkeypatch.setenv("UPSTREAM_DELAY_MS", "20")
    monkeypatch.setenv("UPSTREAM_TIMEOUT_MS", "1")

    response = client.get("/reservations/abc123")

    assert response.status_code == 504
