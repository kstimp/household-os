# Household OS

A unified, cloud-hosted, **family-private** home operations platform. Household OS
consolidates meal planning, grocery automation, personal finance, and ambient
notifications into a single space — reducing reliance on a pile of fragmented SaaS
apps — while staying cheap to run and gated so that **only allowlisted family Google
accounts** can reach it.

> **Status: early build.** The full design is specified in
> [`docs/design-doc`](docs/design-doc). What's actually implemented today is **Phase 1**:
> the cloud infrastructure and the self-hosted [Actual Budget](https://actualbudget.org)
> finance stack (plus an MCP budget server and a standalone college-fund calculator). The
> Hub backend, meal planner, e-ink panel, and Whole Foods automation are designed but not
> yet built. See the [roadmap](#roadmap).

---

## What's here today

| Area | What it is | Where |
|---|---|---|
| **Cloud infrastructure** | Terraform for a Hetzner VPS + volume, Cloudflare DNS/Access/Origin-cert/R2 | [`infra/terraform/`](infra/terraform/) |
| **Actual Budget stack** | Docker Compose for Actual + Caddy (TLS), backup/restore scripts | [`infra/actual/`](infra/actual/) |
| **MCP budget server** | AI (Claude) natural-language access to the budget over MCP | [`docs/mcp-budget-server.md`](docs/mcp-budget-server.md) |
| **College fund calculator** | Small standalone Node/Express + SQLite savings app | [`infra/college/`](infra/college/) |
| **Design & decisions** | Full system design doc + Architecture Decision Records | [`docs/`](docs/), [`docs/decisions/`](docs/decisions/) |
| **Operations runbooks** | Backups, OS/app updates, restores | [`docs/runbook-*.md`](docs/) |

---

## Key principles

These come straight from the [design doc](docs/design-doc) and shape every decision:

- **Family-private, cloud-hosted.** Access is gated at the edge by **Cloudflare Access**
  (Google SSO + an explicit family email allowlist). No custom auth code, no VPN client for
  family members to install.
- **Low cost, not zero.** Accept ~$8–10/month of hosting in exchange for friction-free family
  access. Favor open-source tools and free tiers.
- **No two-way sync, ever.** Every external surface is either a read-only **mirror** (Google
  Calendar, Actual finance) or **owned** by Household OS (shopping board, chores). This avoids
  all conflict-resolution complexity.
- **Wrap and delegate.** Where a good tool already exists (Actual for budgeting), Household OS
  wraps it rather than reimplementing it.
- **Silent failure is the enemy.** Background workers are instrumented with dead-man's switches,
  per-worker heartbeats surfaced in-product, and error tracking.

## Architecture at a glance

```
Browser / phone ─▶ Cloudflare Access (Google SSO + family allowlist)
                        │
                        ▼
              Cloudflare proxy ─▶ Caddy (TLS) ─▶ services on a Hetzner VPS
                                                   ├─ Actual Budget (finance, source of truth)
                                                   ├─ MCP budget server (AI access)
                                                   └─ College fund calculator
                                                        │
                                              persistent volume (SQLite data + backups → R2)
```

The full component diagram, data-flow model, and trust boundaries are in
[`docs/design-doc`](docs/design-doc) §3–§4.

---

## Getting started

Everything runs on one Hetzner VPS behind Cloudflare. You provision with Terraform, then
deploy the Docker stack over SSH.

1. **Provision + deploy Actual Budget** — the foundational Phase 1 setup, from zero accounts:
   [`docs/install-actual.md`](docs/install-actual.md) (60–90 min, ~$8–10/mo).
2. **Add AI budget access (optional)** — deploy the MCP budget server:
   [`docs/mcp-budget-server.md`](docs/mcp-budget-server.md).
3. **Add the finance API sidecar (optional, Phase 2 prep)** —
   [`docs/install-actual-http-api.md`](docs/install-actual-http-api.md).

> These are detailed, copy-paste runbooks with both **bash** (macOS/Linux) and
> **PowerShell** (Windows) command variants. You need a domain on Cloudflare, a Hetzner
> account, and Terraform installed locally.

### Repository layout

```
infra/
  terraform/   # Hetzner VPS + volume, Cloudflare DNS/Access/Origin-cert/R2
  actual/      # docker-compose + Caddyfile for Actual + Caddy; backup/restore scripts
  college/     # standalone college-fund calculator (Node/Express + SQLite)
docs/
  design-doc            # the full system design specification
  install-*.md          # from-zero setup runbooks
  runbook-*.md          # operational runbooks (backups, updates, restores)
  mcp-budget-server.md  # AI-over-MCP budget access
  decisions/            # Architecture Decision Records (ADRs)
```

---

## Operations

Day-two runbooks live in [`docs/`](docs/):

- [Backups & restore](docs/runbook-backups.md)
- [OS security updates](docs/runbook-os-updates.md)
- [Actual Budget updates](docs/runbook-actual-updates.md)
- [MCP server updates](docs/runbook-mcp-updates.md)
- [College app updates](docs/runbook-college-updates.md)

---

## Roadmap

From [`docs/design-doc`](docs/design-doc) §7:

- [x] **Phase 1 — Environment & finance.** Cloud host + SQLite-on-volume, Cloudflare Access,
      Actual Budget deployed, backups. *(MCP budget server and college calculator also landed.)*
- [ ] **Phase 2 — Meal & cart core.** Hub backend, unified grocery list, Whole Foods cart automation.
- [ ] **Phase 3 — Rich web UI.** Responsive SPA for scheduling meals, editing tasks, the unified feed.
- [ ] **Phase 4 — E-ink kitchen display.** Server-rendered dashboard image + touch-zone interactions.

Open questions and spikes are tracked in [`docs/design-doc`](docs/design-doc) §8.

---

## Contributing

Contributions and agent-driven changes are welcome. Please read:

- **[CONTRIBUTING.md](CONTRIBUTING.md)** — workflow, commit conventions, how to propose changes, and the ADR process.
- **[AGENTS.md](AGENTS.md)** — conventions and guardrails for AI coding agents working in this repo.

This is a private family project; there's no license granted for external reuse.
