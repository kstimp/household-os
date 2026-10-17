# 0007 — Budget KPIs on the landing page via a server-side snapshot

- **Status:** Accepted
- **Date:** 2026-10-17
- **Deciders:** Household OS owner
- **Related:** design-doc §2.4/§3.1 (finance integration, Hub backend), ADR-0002 (MCP write
  path), `docs/install-actual-http-api.md`, `docs/runbook-landing-updates.md` §4

## Context

The hub landing page (apex, static, behind Cloudflare Access) has a Money card. We want it to
show budget-hygiene figures — uncategorized transactions, overspent categories, unreconciled
transactions, days since the stalest account was reconciled — so the family sees at a glance
whether the budget needs attention.

The page is static HTML with no backend. The Hub backend that the design doc expects to own
this kind of data is Phase 2 and not built. The `actual-http-api` sidecar already exposes the
needed reads, but it is gated only by a static `X-Api-Key`, which must never reach a browser.

## Decision

Add a tiny **`budget-kpis`** compose service: a stdlib-only Python script on a stock
`python:3.13-alpine` image (no build step) that every 15 minutes `GET`s accounts,
transactions and the current budget month from `actual-http-api` over the internal network,
computes the four figures, and atomically writes `budget-kpis.json` into a `landing_data`
volume. Caddy serves that volume at `/data/*` on the apex, so the JSON inherits the apex's
Cloudflare Access gate. The page fetches it and shows its age, flagging snapshots older than
an hour as stale.

This is a **read-only** finance flow: no writes to Actual, so it does not touch the
"write-back only via MCP" line from ADR-0002.

## Alternatives considered

| Option | Verdict |
|---|---|
| **Snapshot sidecar → static JSON** (chosen) | Key stays server-side; no new public host, Access app or cert; page stays static; ~150 lines of stdlib Python. Cost: figures up to 15 min old (shown on the card). |
| Browser calls `actual-http-api` directly | Would put the API key — full read/write access to the budget — in page source. Rejected. |
| Small proxy endpoint behind the apex | Live numbers, but a long-running HTTP service to build and secure for figures that change a few times a day. Not worth it before the Hub exists. |
| Wait for the Phase 2 Hub backend | Correct long-term home; nothing to show until then. When the Hub lands it can absorb this and the service can be deleted. |
| Host cron + `curl`/`jq` against the public `actual-api` host | Works, but logic in shell/jq is harder to read and test, and it routes internal traffic out through Cloudflare. |

## Consequences

- One more container, reusing the `actual-http-api` key (in its own gitignored
  `budget-kpis.env`, so the KPI container never sees the Actual server password).
- "Last reconciled" is a **proxy** (newest reconciled transaction date per account), because
  `@actual-app/api` does not expose the account's `last_reconciled` timestamp.
- The current month is computed in UTC, so "overspent" can lag by a few hours at month start.
- Account and category names appear in the JSON; acceptable because it is behind the same
  family-only Access app as the page.
- Superseded once the Hub backend serves this data; delete the service then.
