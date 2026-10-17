"""Budget KPI snapshotter for the hub landing page.

Polls the Actual HTTP API sidecar (actual-http-api) over the internal compose network,
computes a handful of budget-hygiene KPIs, and writes them as a small JSON file that
Caddy serves under the apex at /data/budget-kpis.json (behind Cloudflare Access).

Read-only: only GET requests are made. The API key never leaves the server — the
browser only ever sees the computed numbers. Stdlib only, so it runs on a stock
python image with no build step.

Env:
  ACTUAL_API_URL                     default http://actual-http-api:5007/v1
  ACTUAL_API_KEY                     required (same value as API_KEY in actual-http-api.env)
  ACTUAL_BUDGET_SYNC_ID              required
  ACTUAL_BUDGET_ENCRYPTION_PASSWORD  optional, only for E2E-encrypted budgets
  KPI_OUT_PATH                       default /out/budget-kpis.json
  KPI_INTERVAL_SECONDS               default 900; 0 = run once and exit
"""

import json
import os
import sys
import time
import urllib.parse
import urllib.request
from datetime import date, datetime, timezone

API_URL = os.environ.get("ACTUAL_API_URL", "http://actual-http-api:5007/v1").rstrip("/")
API_KEY = os.environ.get("ACTUAL_API_KEY", "")
SYNC_ID = os.environ.get("ACTUAL_BUDGET_SYNC_ID", "")
ENCRYPTION_PASSWORD = os.environ.get("ACTUAL_BUDGET_ENCRYPTION_PASSWORD", "")
OUT_PATH = os.environ.get("KPI_OUT_PATH", "/out/budget-kpis.json")
INTERVAL = int(os.environ.get("KPI_INTERVAL_SECONDS", "900"))

# getTransactions requires a lower bound; we want full history.
SINCE_DATE = "1970-01-01"


def log(msg):
    print(f"{datetime.now(timezone.utc).isoformat(timespec='seconds')} {msg}", flush=True)


def api_get(path, **params):
    url = f"{API_URL}/budgets/{urllib.parse.quote(SYNC_ID)}{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    headers = {"X-Api-Key": API_KEY, "Accept": "application/json"}
    if ENCRYPTION_PASSWORD:
        headers["budget-encryption-password"] = ENCRYPTION_PASSWORD
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.load(resp)["data"]


def leaves(txn):
    """A split parent carries no category itself; its children do."""
    if txn.get("is_parent"):
        return txn.get("subtransactions") or []
    return [txn]


def compute(today):
    month = today.strftime("%Y-%m")
    accounts = api_get("/accounts")
    offbudget = {a["id"]: a["offbudget"] for a in accounts}

    txns_by_account = {
        a["id"]: api_get(f"/accounts/{a['id']}/transactions", since_date=SINCE_DATE)
        for a in accounts
    }
    # transfer_id points at the counterpart transaction; we need its account to know
    # whether the transfer crosses the on/off-budget line.
    account_of_txn = {}
    for acct_id, txns in txns_by_account.items():
        for t in txns:
            account_of_txn[t["id"]] = acct_id

    # Uncategorized — mirrors Actual's own "uncategorized" view: on-budget accounts,
    # no category, excluding transfers between two on-budget accounts (those need none).
    uncategorized = 0
    for acct_id, txns in txns_by_account.items():
        if offbudget[acct_id]:
            continue
        for t in txns:
            for leaf in leaves(t):
                if leaf.get("category") or leaf.get("starting_balance_flag"):
                    continue
                other = account_of_txn.get(leaf.get("transfer_id"))
                if other is not None and not offbudget.get(other, True):
                    continue
                uncategorized += 1

    # Reconciliation — open, on-budget accounts only (off-budget trackers such as
    # investments are rarely reconciled and would just be noise). The API doesn't
    # expose Actual's last_reconciled timestamp, so we use the newest reconciled
    # transaction's date as the proxy.
    unreconciled = 0
    reconciliation = []
    for a in accounts:
        if a["closed"] or a["offbudget"]:
            continue
        txns = txns_by_account[a["id"]]
        unreconciled += sum(1 for t in txns if not t.get("reconciled"))
        reconciled_dates = [t["date"] for t in txns if t.get("reconciled")]
        reconciliation.append({
            "account": a["name"],
            "last_reconciled": max(reconciled_dates) if reconciled_dates else None,
        })
    # Stalest first: never-reconciled accounts sort ahead of any date.
    reconciliation.sort(key=lambda r: r["last_reconciled"] or "")

    # Overspent — expense categories with a negative balance this month.
    budget_month = api_get(f"/months/{month}")
    overspent = sorted(
        c["name"]
        for g in budget_month["categoryGroups"]
        if not g.get("is_income")
        for c in g["categories"]
        if not c.get("hidden") and (c.get("balance") or 0) < 0
    )

    return {
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "month": month,
        "uncategorized_transactions": uncategorized,
        "overspent_categories": len(overspent),
        "overspent_category_names": overspent,
        "unreconciled_transactions": unreconciled,
        "stalest_reconciliation": reconciliation[0] if reconciliation else None,
        "accounts": reconciliation,
    }


def write_atomic(path, payload):
    tmp = f"{path}.tmp"
    with open(tmp, "w") as f:
        json.dump(payload, f, indent=2)
    os.replace(tmp, path)


def run_once():
    payload = compute(date.today())
    write_atomic(OUT_PATH, payload)
    log(
        f"wrote {OUT_PATH}: uncategorized={payload['uncategorized_transactions']} "
        f"overspent={payload['overspent_categories']} "
        f"unreconciled={payload['unreconciled_transactions']}"
    )


def main():
    if not API_KEY or not SYNC_ID:
        # Idle rather than exit: under `restart: unless-stopped` an exit is a crash loop.
        log("ACTUAL_API_KEY / ACTUAL_BUDGET_SYNC_ID not set (budget-kpis.env); idling")
        while True:
            time.sleep(3600)
    while True:
        try:
            run_once()
        except Exception as exc:  # keep polling; the page flags a stale snapshot
            log(f"refresh failed, keeping previous snapshot: {exc!r}")
            if INTERVAL == 0:
                sys.exit(1)
        if INTERVAL == 0:
            return
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
