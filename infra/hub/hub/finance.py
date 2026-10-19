"""Finance worker: budget-hygiene KPIs mirrored from Actual (design §2.4).

`compute_kpis` is pure (data in, dict out) so it can be tested without Actual;
`refresh` does the fetching.
"""

from datetime import date, datetime, timezone

from .actual import ActualClient


def _leaves(txn: dict) -> list[dict]:
    """A split parent carries no category itself; its children do."""
    if txn.get("is_parent"):
        return txn.get("subtransactions") or []
    return [txn]


def compute_kpis(accounts: list[dict], txns_by_account: dict[str, list[dict]],
                 budget_month: dict, month: str) -> dict:
    offbudget = {a["id"]: a["offbudget"] for a in accounts}

    # transfer_id points at the counterpart transaction; we need its account to know
    # whether the transfer crosses the on/off-budget line.
    account_of_txn = {t["id"]: acct_id for acct_id, txns in txns_by_account.items() for t in txns}

    # Uncategorized — mirrors Actual's own "uncategorized" view: on-budget accounts,
    # no category, excluding transfers between two on-budget accounts (those need none).
    uncategorized = 0
    for acct_id, txns in txns_by_account.items():
        if offbudget[acct_id]:
            continue
        for t in txns:
            for leaf in _leaves(t):
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

    # Overspent — visible expense categories with a negative balance this month.
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


def refresh(client: ActualClient, today: date | None = None) -> dict:
    month = (today or date.today()).strftime("%Y-%m")
    accounts = client.accounts()
    txns_by_account = {a["id"]: client.transactions(a["id"]) for a in accounts}
    return compute_kpis(accounts, txns_by_account, client.budget_month(month), month)
