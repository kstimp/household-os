from fastapi.testclient import TestClient

from hub.config import Settings
from hub.main import FINANCE_WORKER, create_app


def settings(tmp_path, configured=True):
    return Settings(
        db_path=str(tmp_path / "hub.db"),
        actual_api_url="http://unused",
        actual_api_key="k" if configured else "",
        actual_sync_id="s" if configured else "",
        actual_encryption_password="",
        finance_interval_seconds=900,
    )


def test_kpis_503_before_first_snapshot(tmp_path):
    app = create_app(settings(tmp_path), start_workers=False)
    with TestClient(app) as c:
        assert c.get("/api/budget/kpis").status_code == 503


def test_worker_success_is_served_with_heartbeat(tmp_path):
    app = create_app(settings(tmp_path), start_workers=False)
    worker = app.state.workers[0]
    worker.job = lambda: app.state.db.save_budget_kpis(
        {"generated_at": "2026-10-19T12:00:00+00:00", "uncategorized_transactions": 2})
    worker.run_once()
    with TestClient(app) as c:
        body = c.get("/api/budget/kpis").json()
        assert body["uncategorized_transactions"] == 2
        assert body["worker"]["last_error"] is None
        assert body["worker"]["stale"] is False
        assert c.get("/api/health").json()["status"] == "ok"


def test_worker_failure_keeps_snapshot_and_reports_error(tmp_path):
    app = create_app(settings(tmp_path), start_workers=False)
    app.state.db.save_budget_kpis({"generated_at": "2026-10-19T12:00:00+00:00"})
    worker = app.state.workers[0]

    def boom():
        raise ConnectionError("actual-http-api down")

    worker.job = boom
    worker.run_once()
    with TestClient(app) as c:
        body = c.get("/api/budget/kpis").json()
        assert "actual-http-api down" in body["worker"]["last_error"]
        health = c.get("/api/health").json()
        assert health["status"] == "degraded"
        assert health["workers"][FINANCE_WORKER]["stale"] is True


def test_unconfigured_finance_is_reported_not_crashed(tmp_path):
    app = create_app(settings(tmp_path, configured=False))
    with TestClient(app) as c:
        health = c.get("/api/health").json()
        assert health["workers"][FINANCE_WORKER] == {"configured": False}
        assert health["status"] == "ok"
