"""Household OS Hub backend — minimal Phase 1 slice.

Serves a small JSON API under /api, routed by Caddy on the apex (behind Cloudflare
Access, so no app-level auth — design §4.1). Runs the finance worker in-process.
"""

import logging
import os
from contextlib import asynccontextmanager
from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException

from . import config, finance
from .actual import ActualClient
from .db import Database
from .worker import PeriodicWorker

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("hub")

FINANCE_WORKER = "finance"


def worker_view(status: dict | None, interval_seconds: int) -> dict:
    """Heartbeat plus a `stale` flag: no success within two intervals."""
    if status is None:
        return {"last_run_at": None, "last_success_at": None, "last_error": None, "stale": True}
    stale = True
    if status["last_success_at"]:
        age = datetime.now(timezone.utc) - datetime.fromisoformat(status["last_success_at"])
        stale = age.total_seconds() > 2 * interval_seconds
    return {**{k: status[k] for k in ("last_run_at", "last_success_at", "last_error")}, "stale": stale}


def create_app(settings: config.Settings | None = None, start_workers: bool = True) -> FastAPI:
    settings = settings or config.load()
    db_dir = os.path.dirname(settings.db_path)
    if db_dir:
        os.makedirs(db_dir, exist_ok=True)
    database = Database(settings.db_path)

    workers: list[PeriodicWorker] = []
    if settings.finance_configured:
        client = ActualClient(settings.actual_api_url, settings.actual_api_key,
                              settings.actual_sync_id, settings.actual_encryption_password)
        workers.append(PeriodicWorker(
            FINANCE_WORKER, settings.finance_interval_seconds,
            lambda: database.save_budget_kpis(finance.refresh(client)), database,
        ))
    else:
        log.warning("ACTUAL_API_KEY / ACTUAL_BUDGET_SYNC_ID not set (hub.env); finance worker disabled")

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        if start_workers:
            for w in workers:
                w.start()
        yield
        for w in workers:
            w.stop()

    app = FastAPI(title="Household OS Hub", lifespan=lifespan, docs_url="/api/docs",
                  openapi_url="/api/openapi.json")
    app.state.db = database
    app.state.workers = workers

    @app.get("/api/health")
    def health():
        statuses = {s["name"]: s for s in database.worker_statuses()}
        out = {}
        for w in workers:
            out[w.name] = worker_view(statuses.get(w.name), w.interval)
        if not settings.finance_configured:
            out[FINANCE_WORKER] = {"configured": False}
        ok = all(not v.get("stale") and not v.get("last_error") for v in out.values()
                 if v.get("configured", True))
        return {"status": "ok" if ok else "degraded", "workers": out}

    @app.get("/api/budget/kpis")
    def budget_kpis():
        snapshot = database.load_budget_kpis()
        if snapshot is None:
            raise HTTPException(status_code=503, detail="No budget snapshot yet")
        status = worker_view(database.worker_status(FINANCE_WORKER),
                             settings.finance_interval_seconds)
        return {**snapshot, "worker": status}

    return app

