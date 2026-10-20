"""Read-only client for the actual-http-api sidecar (docs/install-actual-http-api.md).

Only GETs. Finance is a mirror (design §2.6): the Hub never writes to Actual.
"""

import json
import urllib.error
import urllib.parse
import urllib.request

# getTransactions requires a lower bound; we want full history.
SINCE_DATE = "1970-01-01"


class ActualApiError(Exception):
    pass


class ActualClient:
    def __init__(self, base_url: str, api_key: str, sync_id: str, encryption_password: str = ""):
        self.base = f"{base_url}/budgets/{urllib.parse.quote(sync_id)}"
        self.headers = {"X-Api-Key": api_key, "Accept": "application/json"}
        if encryption_password:
            self.headers["budget-encryption-password"] = encryption_password

    def _get(self, path: str, **params):
        url = self.base + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, headers=self.headers)
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                return json.load(resp)["data"]
        except urllib.error.HTTPError as exc:
            # actual-http-api explains failures in a JSON {"error": ...} body; without it a
            # bare 404 is undiagnosable (it usually means the budget couldn't be loaded).
            body = exc.read().decode("utf-8", "replace")
            try:
                parsed = json.loads(body)
                detail = parsed.get("error", body) if isinstance(parsed, dict) else body
            except ValueError:
                detail = body
            raise ActualApiError(f"{exc.code} from GET {path}: {detail.strip()[:300]}") from None

    def accounts(self) -> list[dict]:
        return self._get("/accounts")

    def transactions(self, account_id: str) -> list[dict]:
        return self._get(f"/accounts/{account_id}/transactions", since_date=SINCE_DATE)

    def budget_month(self, month: str) -> dict:
        return self._get(f"/months/{month}")
