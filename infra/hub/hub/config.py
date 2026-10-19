"""Settings, read once from the environment (hub.env + docker-compose.yml)."""

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    db_path: str
    actual_api_url: str
    actual_api_key: str
    actual_sync_id: str
    actual_encryption_password: str
    finance_interval_seconds: int

    @property
    def finance_configured(self) -> bool:
        return bool(self.actual_api_key and self.actual_sync_id)


def load() -> Settings:
    return Settings(
        db_path=os.environ.get("HUB_DB_PATH", "hub.db"),
        actual_api_url=os.environ.get("ACTUAL_API_URL", "http://actual-http-api:5007/v1").rstrip("/"),
        actual_api_key=os.environ.get("ACTUAL_API_KEY", ""),
        actual_sync_id=os.environ.get("ACTUAL_BUDGET_SYNC_ID", ""),
        actual_encryption_password=os.environ.get("ACTUAL_BUDGET_ENCRYPTION_PASSWORD", ""),
        finance_interval_seconds=int(os.environ.get("FINANCE_INTERVAL_SECONDS", "900")),
    )
