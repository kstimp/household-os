# 0008 — Start the Hub backend in Python/FastAPI, reading Actual via the actual-http-api sidecar

- **Status:** Accepted
- **Date:** 2026-10-20
- **Deciders:** Household OS owner
- **Amends:** design-doc §3.1 ("Node.js (Express/Fastify) recommended")
- **Related:** ADR-0007 (origin lockdown), design-doc §2.4 (finance mirror), §2.6 (no write-back), §5.2 (heartbeats),
  §7 Phase 1 ("build a worker to pull and cache budget balances"),
  `docs/install-actual-http-api.md`, `docs/runbook-hub-updates.md`

## Context

The landing page's Money card should show budget-hygiene KPIs (uncategorized transactions,
overspent categories, unreconciled transactions, days since last reconciliation). The page is
static, so the figures need a server-side component that can hold the Actual credentials.

The roadmap already calls for exactly that in Phase 1 — a worker that pulls and caches budget
balances — and the design places it in the Hub backend. Building a one-off sidecar would be
throwaway work, so we start the Hub now with the smallest slice that delivers this feature.

§3.1 recommends Node because `@actual-app/api` is Node-only, while noting that a Python Hub
works with an `actual-http-api` sidecar. That sidecar has since been deployed
(`install-actual-http-api.md`, which already anticipates a "Hub backend (Python/FastAPI)"),
and the owner works primarily in Python.

## Decision

- The Hub backend is **Python 3.13 + FastAPI**, in `infra/hub/`, run as the `hub` service in
  the existing compose stack.
- It reads Actual **only through `actual-http-api`**, GET requests only, over the internal
  network. Finance stays a read-only mirror (§2.6); write-back remains MCP-only (ADR-0002).
- It is served at **`/api/*` on the apex**, routed by Caddy. Same origin as the landing page, so
  it inherits the apex's Cloudflare Access app — no app-level auth (§4.1), no CORS, no new
  host, DNS record or certificate.
- State is **SQLite on the volume** (`/mnt/data/hub/hub.db`): per-worker heartbeats
  (`last_success_at` / `last_error`, §5.2) and the latest budget KPI snapshot.
- Background workers run **in-process** (a thread per worker). One process, no queue.

**Scope of this slice:** the finance worker, `GET /api/health`, `GET /api/budget/kpis`. The
rest of §3 (Litestream, healthchecks.io dead-man's switch, Sentry, the SPA, calendar/meals/
tasks) is deliberately not built yet. Litestream is safe to defer because the only data is a
cache of Actual that rebuilds on the next run; it becomes mandatory with the first table the
Hub *owns* (e.g. the shopping board).

## Alternatives considered

| Option | Verdict |
|---|---|
| **Python/FastAPI + actual-http-api** (chosen) | Owner's language; sidecar already deployed and maintained; small, readable code with tests. Cost: one network hop, and a dependency on a third-party wrapper's REST shape. |
| Node/Fastify + `@actual-app/api` in-process (§3.1 as written) | Official client, no extra hop. But the Hub would keep a *third* synced budget copy (after MCP and the sidecar), and the owner would maintain a Node codebase. |
| Standalone KPI sidecar writing static JSON (first draft of this PR) | Smallest code, but a dead end — the Hub would replace it. |
| Python + `actualpy` | Pure Python, but an unofficial reimplementation of Actual's sync protocol that can break on Actual upgrades. The sidecar tracks Actual's releases. |

## Consequences

- §3.1 now reads Python/FastAPI; the design's Node rationale is kept as history.
- The Hub's finance features are limited to what `actual-http-api` exposes. Notably Actual's
  `last_reconciled` account field is not exposed, so "days since reconciled" uses the newest
  reconciled transaction's date as a proxy.
- `actual-http-api` and Actual versions must stay in step (already the sidecar's rule).
- The current month for "overspent" is computed in UTC — can lag by hours at month start.
- `/api` serves finance summaries from the apex, so it relies on Cloudflare Access not being
  bypassable. ADR-0007 (origin firewall admits only Cloudflare IPs) provides that; the Hub
  adds no app-level auth of its own. Origin-side Access JWT validation remains the noted
  upgrade path.
