"""SQLite on the persistent volume (design §3.1).

Two tables for now:
- worker_status: per-worker heartbeat (design §5.2) so staleness is visible in the product.
- budget_kpis: the latest finance snapshot. A cache of Actual (the source of truth), so it
  is safe to lose — the worker rebuilds it on the next run.
"""

import json
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone

SCHEMA = """
CREATE TABLE IF NOT EXISTS worker_status (
    name            TEXT PRIMARY KEY,
    last_run_at     TEXT,
    last_success_at TEXT,
    last_error      TEXT
);
CREATE TABLE IF NOT EXISTS budget_kpis (
    id           INTEGER PRIMARY KEY CHECK (id = 1),
    generated_at TEXT NOT NULL,
    payload      TEXT NOT NULL
);
"""


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


class Database:
    """Opens a short-lived connection per call: the worker thread and FastAPI's
    threadpool both use it, and SQLite (WAL mode) handles the concurrency."""

    def __init__(self, path: str):
        self.path = path
        with self._connect() as conn:
            conn.execute("PRAGMA journal_mode=WAL")
            conn.executescript(SCHEMA)

    @contextmanager
    def _connect(self):
        conn = sqlite3.connect(self.path, timeout=10)
        conn.row_factory = sqlite3.Row
        try:
            with conn:  # commits on success, rolls back on error
                yield conn
        finally:
            conn.close()

    def record_success(self, worker: str) -> None:
        ts = now_iso()
        with self._connect() as conn:
            conn.execute(
                """INSERT INTO worker_status (name, last_run_at, last_success_at, last_error)
                   VALUES (?, ?, ?, NULL)
                   ON CONFLICT(name) DO UPDATE SET
                     last_run_at = excluded.last_run_at,
                     last_success_at = excluded.last_success_at,
                     last_error = NULL""",
                (worker, ts, ts),
            )

    def record_failure(self, worker: str, error: str) -> None:
        with self._connect() as conn:
            conn.execute(
                """INSERT INTO worker_status (name, last_run_at, last_error)
                   VALUES (?, ?, ?)
                   ON CONFLICT(name) DO UPDATE SET
                     last_run_at = excluded.last_run_at,
                     last_error = excluded.last_error""",
                (worker, now_iso(), error),
            )

    def worker_statuses(self) -> list[dict]:
        with self._connect() as conn:
            return [dict(r) for r in conn.execute("SELECT * FROM worker_status ORDER BY name")]

    def worker_status(self, worker: str) -> dict | None:
        with self._connect() as conn:
            row = conn.execute("SELECT * FROM worker_status WHERE name = ?", (worker,)).fetchone()
        return dict(row) if row else None

    def save_budget_kpis(self, payload: dict) -> None:
        with self._connect() as conn:
            conn.execute(
                """INSERT INTO budget_kpis (id, generated_at, payload) VALUES (1, ?, ?)
                   ON CONFLICT(id) DO UPDATE SET
                     generated_at = excluded.generated_at, payload = excluded.payload""",
                (payload["generated_at"], json.dumps(payload)),
            )

    def load_budget_kpis(self) -> dict | None:
        with self._connect() as conn:
            row = conn.execute("SELECT payload FROM budget_kpis WHERE id = 1").fetchone()
        return json.loads(row["payload"]) if row else None
