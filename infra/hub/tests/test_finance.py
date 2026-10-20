from hub.finance import compute_kpis

ACCOUNTS = [
    {"id": "chk", "name": "Checking", "offbudget": False, "closed": False},
    {"id": "cc", "name": "Visa", "offbudget": False, "closed": False},
    {"id": "inv", "name": "401k", "offbudget": True, "closed": False},
    {"id": "old", "name": "Old savings", "offbudget": False, "closed": True},
]
TXNS = {
    "chk": [
        {"id": "t1", "date": "2026-09-01", "category": "food", "reconciled": True},
        {"id": "t2", "date": "2026-10-10", "category": None},                     # uncategorized
        {"id": "t3", "date": "2026-10-11", "category": None, "transfer_id": "t5"},  # on->on transfer
        {"id": "t4", "date": "2026-10-12", "category": None, "transfer_id": "t6"},  # on->off: needs one
        {"id": "t7", "date": "2026-10-12", "is_parent": True, "category": None,
         "subtransactions": [{"id": "t7a", "category": "food"}, {"id": "t7b", "category": None}]},
        {"id": "t8", "date": "2026-01-01", "category": None, "starting_balance_flag": True,
         "reconciled": True},
    ],
    "cc": [{"id": "t5", "date": "2026-10-11", "category": None, "transfer_id": "t3"}],
    "inv": [{"id": "t6", "date": "2026-10-12", "category": None, "transfer_id": "t4"}],
    "old": [{"id": "t9", "date": "2020-01-01", "category": None}],               # closed, still counts
}
MONTH = {"categoryGroups": [
    {"is_income": False, "categories": [
        {"name": "Food", "balance": -500},
        {"name": "Gas", "balance": 100},
        {"name": "Hidden", "hidden": True, "balance": -5},
    ]},
    {"is_income": True, "categories": [{"name": "Salary", "balance": -1}]},
]}


def kpis():
    return compute_kpis(ACCOUNTS, TXNS, MONTH, "2026-10")


def test_uncategorized_matches_actual_view():
    # t2, t4 (transfer to off-budget), t7b (split child), t9 (closed on-budget account)
    assert kpis()["uncategorized_transactions"] == 4


def test_overspent_ignores_hidden_and_income():
    k = kpis()
    assert k["overspent_categories"] == 1
    assert k["overspent_category_names"] == ["Food"]


def test_unreconciled_counts_open_on_budget_top_level_only():
    # chk: t2, t3, t4, t7 ; cc: t5 — not inv (off-budget) or old (closed)
    assert kpis()["unreconciled_transactions"] == 5


def test_stalest_reconciliation_puts_never_first():
    k = kpis()
    assert k["stalest_reconciliation"] == {"account": "Visa", "last_reconciled": None}
    assert k["accounts"][1] == {"account": "Checking", "last_reconciled": "2026-09-01"}


def test_no_open_accounts():
    k = compute_kpis([], {}, {"categoryGroups": []}, "2026-10")
    assert k["stalest_reconciliation"] is None
    assert k["uncategorized_transactions"] == 0
