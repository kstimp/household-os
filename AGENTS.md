# AGENTS.md

Guidance for AI coding agents (Claude Code, and any other agent) working in the
**Household OS** repository. Humans should read [CONTRIBUTING.md](CONTRIBUTING.md) too — this
file layers agent-specific guardrails on top of it.

## What this project is

Household OS is a **family-private, cloud-hosted** home-operations platform. Read
[`docs/design-doc`](docs/design-doc) before making non-trivial changes — it is the source of
truth for architecture and, more importantly, for *why* decisions were made. Non-obvious
decisions are recorded as ADRs in [`docs/decisions/`](docs/decisions/).

**Current reality:** the implemented surface is **Phase 1** — Terraform + Docker infra for
Actual Budget, an MCP budget server, a small college-fund calculator, the static landing page,
and a **minimal Hub backend** (Python/FastAPI, ADR-0008) whose only feature so far is a
read-only finance worker serving budget KPIs. The meal planner, e-ink panel, calendar/tasks,
Whole Foods automation and the rest of the Hub are **designed but not built**. Don't assume
code exists for them; don't scaffold them unless explicitly asked.

## Repository map

```
infra/terraform/   # Hetzner VPS + volume, Cloudflare DNS/Access/Origin-cert/R2
infra/actual/      # docker-compose + Caddyfile for Actual + Caddy; backup/restore scripts
infra/college/     # standalone Node/Express + SQLite college-fund calculator
infra/landing/     # static hub landing page (apex), served by Caddy file_server
infra/hub/         # Hub backend: Python/FastAPI + SQLite, served at /api on the apex
docs/              # design-doc, install-*.md setup guides, runbook-*.md ops guides
docs/decisions/    # Architecture Decision Records
```

## Golden rules

1. **Never commit or print secrets.** See CONTRIBUTING.md → Secrets. Real values live in
   gitignored files (`terraform.tfvars`, `*.env`, `*.key`, `certs/`, `*.tfstate`). Only the
   `*.example` templates belong in git. If you find a leaked secret, stop and flag it — do not
   quietly move on.
2. **Respect the design, or amend it explicitly.** If a request conflicts with the design doc
   (e.g. two-way sync, writing back to Actual outside the MCP path, an app-level auth system),
   surface the conflict instead of silently implementing it. If the change is genuinely wanted,
   update the design doc and add an ADR.
3. **Don't touch the COOP/COEP header handling** in `infra/actual/Caddyfile`. Actual sets those
   headers itself; adding or duplicating them at the proxy breaks Actual with
   `SharedArrayBufferMissing`. This is a known, documented footgun.
4. **Keep docs and infra in lockstep.** If you change Terraform, Compose, or a script, update
   the matching `install-*.md` / `runbook-*.md` in the same change. A runbook that no longer
   matches reality is a bug.
5. **Prefer wrap-and-delegate.** Don't reimplement functionality a wrapped tool already owns
   (budgeting logic lives in Actual, not here).
6. **Scope discipline.** Make the smallest change that satisfies the request. Don't refactor
   adjacent code, rename things, or "upgrade" the free-text meal-planner model into a structured
   ingredient engine (the design deliberately keeps it free-text — see design §2.1).

## Conventions

- **Commits:** Conventional Commits — `type(scope): summary` in the imperative
  (e.g. `docs(actual): clarify restore vs UI export`). Types: `feat`, `fix`, `docs`, `chore`,
  `refactor`. Scopes: `college`, `terraform`, `actual`, `mcp`, etc.
- **Branches & PRs:** work on a descriptive feature branch and open a PR into `main` using the
  [PR template](.github/PULL_REQUEST_TEMPLATE.md). Don't push directly to `main`.
- **Runbooks:** setup guides target a from-zero first-timer and include both **bash** and
  **PowerShell** variants for commands that run on the user's machine. Match that style.
- **Node code** (`infra/college/`): ES modules, `better-sqlite3` for storage. Match the
  existing style; don't add a framework or build step without being asked.
- **Hub code** (`infra/hub/`): Python 3.13, FastAPI, stdlib `sqlite3` and `urllib`. Pinned
  `requirements.txt`; keep dependencies minimal. Pure logic in testable functions, with pytest
  tests in `infra/hub/tests/`. Finance access is read-only via `actual-http-api`.
- **Terraform:** run `terraform fmt` and `terraform validate`; keep `terraform.tfvars.example`
  in sync with any new variable.

## Verification before you claim done

There is no heavy CI. Verify with the right lightweight check and report what you ran:

- Terraform: `terraform fmt -check`, `terraform validate`, and read the `plan` — never
  `apply` from an unreviewed plan.
- Docker: `docker compose config` to validate; `docker compose up -d` + `docker compose ps`
  to confirm health where feasible.
- College app: `npm install && npm start` and exercise the affected path.
- Hub: `cd infra/hub && pip install -r requirements-dev.txt && pytest`; for API changes also
  run `uvicorn hub.main:create_app --factory` and hit the endpoints.
- Docs: re-read your change end-to-end as if following it fresh.

State plainly what you verified and what you couldn't (e.g. steps requiring live Cloudflare/
Hetzner credentials you don't have). Don't imply an infra step succeeded if you only edited a
file.

## When to ask vs. proceed

Proceed on clear, in-scope changes with sensible defaults. **Ask a human first** when a change
would: alter hosting/auth/the sync model, spend money, weaken the access gate, touch finance
data flow, cross the "no write-back to Actual" line, or contradict the design doc. Use the
project's decision log (ADR) for anything future-you would question.

---

*Claude Code reads `CLAUDE.md`; it points here so there's a single source of truth.*
