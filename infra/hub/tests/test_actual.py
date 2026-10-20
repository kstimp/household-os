import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

from hub import config
from hub.actual import ActualApiError, ActualClient


@pytest.fixture
def api_404():
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            body = json.dumps({"error": "Budget not-a-sync-id not found"}).encode()
            self.send_response(404)
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{server.server_port}/v1"
    server.shutdown()


def test_http_error_includes_api_error_body(api_404):
    client = ActualClient(api_404, "k", "not-a-sync-id")
    with pytest.raises(ActualApiError, match=r"404 from GET /accounts: Budget not-a-sync-id not found"):
        client.accounts()


def test_config_strips_whitespace_and_cr(monkeypatch):
    monkeypatch.setenv("ACTUAL_BUDGET_SYNC_ID", "abc-123\r")
    monkeypatch.setenv("ACTUAL_API_KEY", " key ")
    s = config.load()
    assert s.actual_sync_id == "abc-123"
    assert s.actual_api_key == "key"
