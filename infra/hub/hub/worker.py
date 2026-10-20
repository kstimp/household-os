"""In-process scheduler for background workers.

One daemon thread per worker, each recording a heartbeat in SQLite after every run
(design §5.2) so a failing or stalled worker shows up on the dashboard, not just in logs.
"""

import logging
import threading
import traceback

log = logging.getLogger("hub.worker")


class PeriodicWorker:
    def __init__(self, name: str, interval_seconds: int, job, database):
        self.name = name
        self.interval = interval_seconds
        self.job = job
        self.db = database
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._loop, name=f"worker:{name}", daemon=True)

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread.is_alive():
            self._thread.join(timeout=5)

    def run_once(self) -> None:
        try:
            self.job()
        except Exception as exc:
            log.error("%s failed: %r\n%s", self.name, exc, traceback.format_exc())
            self.db.record_failure(self.name, repr(exc))
        else:
            self.db.record_success(self.name)
            log.info("%s ok", self.name)

    def _loop(self) -> None:
        while not self._stop.is_set():
            self.run_once()
            self._stop.wait(self.interval)
