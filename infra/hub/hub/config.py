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


def _env(name: str, default: str = "") -> str:
    # Strip stray whitespace/CR (e.g. hub.env saved with Windows line endings), which
    # would otherwise end up inside the sync ID in the request URL.
    return os.environ.get(name, default).strip()


def load() -> Settings:
    return Settings(
        db_path=_env("HUB_DB_PATH", "hub.db"),
        actual_api_url=_env("ACTUAL_API_URL", "http://actual-http-api:5007/v1").rstrip("/"),
        actual_api_key=_env("ACTUAL_API_KEY"),
        actual_sync_id=_env("ACTUAL_BUDGET_SYNC_ID"),
        actual_encryption_password=_env("ACTUAL_BUDGET_ENCRYPTION_PASSWORD"),
        finance_interval_seconds=int(_env("FINANCE_INTERVAL_SECONDS", "900")),
    )
