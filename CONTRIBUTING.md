# Contributing to Household OS

Thanks for pitching in. This is a small, private family project, so the process is
lightweight — but because it runs real household infrastructure (finance data, a public
VPS, family credentials), a few conventions keep it safe and maintainable.

If you're an AI agent, also read **[AGENTS.md](AGENTS.md)** — it has extra guardrails.

---

## Ground rules

1. **This repo is docs- and infra-heavy.** Most changes are Terraform, Docker Compose,
   shell scripts, and Markdown runbooks — not application code (the Hub backend isn't built
   yet). Treat the runbooks as executable specifications: if you change the infra, update
   the runbook that describes it in the same change.
2. **Never commit secrets.** See [Secrets](#secrets) below. `.gitignore` is your safety net,
   not your first line of defense.
3. **Respect the design.** [`docs/design-doc`](docs/design-doc) is the source of truth for
   *why* things are the way they are. If your change contradicts it, either don't — or update
   the design doc and record an ADR (see [Decisions](#architecture-decisions-adrs)).
4. **Keep it cheap and family-private.** Changes that raise recurring cost, add a new paid
   SaaS dependency, or weaken the Cloudflare Access gate need explicit justification.

---

## Workflow

1. **Branch** off `main`. Use a descriptive branch name, e.g.
   `feat/mcp-rate-limit`, `fix/caddy-coop-header`, `docs/backup-runbook-clarify`.
2. **Make focused commits** following the [commit conventions](#commit-conventions) below.
3. **Update docs alongside code.** A Terraform or Compose change that isn't reflected in the
   relevant `install-*.md` / `runbook-*.md` is incomplete.
4. **Open a pull request** into `main`, filling in the
   [PR template](.github/PULL_REQUEST_TEMPLATE.md). PRs are how changes land — direct pushes
   to `main` are avoided.
5. **Verify before you claim done.** Run the relevant checks (see [Testing & verification](#testing--verification)).

## Commit conventions

This repo uses **[Conventional Commits](https://www.conventionalcommits.org/)**, matching the
existing history:

```
<type>(<optional scope>): <short imperative summary>
```

Common types seen here: `feat`, `fix`, `docs`, `chore`, `refactor`. Scopes are the affected
area, e.g. `college`, `terraform`, `actual`, `mcp`.

Examples from the log:

```
feat(college): add projected balance hover tooltip and yearly targets modal
chore: pinning v0.8.1 of actual-mcp-server
docs: add powershell instructions to college deployment runbook
```

Keep the summary in the imperative mood ("add", not "added"), under ~72 characters, and put
the *why* in the body when it isn't obvious.

---

## Working areas

### Terraform (`infra/terraform/`)

- Run `terraform fmt` and `terraform validate` before committing.
- Never commit `terraform.tfvars`, `*.tfstate`, or the `.terraform/` dir — all gitignored.
  State is stored remotely in HCP Terraform (execution stays local so secrets don't leave
  your machine; see [`docs/install-actual.md`](docs/install-actual.md) Part 6).
- Keep `terraform.tfvars.example` in sync when you add or rename a variable.

### Docker / Actual stack (`infra/actual/`)

- The `Caddyfile` is deliberately written **not** to set or duplicate COOP/COEP headers —
  Actual sets them itself, and duplicating them causes the `SharedArrayBufferMissing` failure.
  Don't "helpfully" add them. (Background: [`docs/install-actual.md`](docs/install-actual.md).)
- Keep `*.env.example` files current; the real `*.env` files are gitignored.
- Pin image versions rather than using `latest` so updates are deliberate and reversible.

### College fund calculator (`infra/college/`)

- Node/Express + `better-sqlite3`, ES modules (`"type": "module"`). Run locally with
  `npm install && npm start` (serves on `PORT`, default 3000).
- Deployment and update steps are in
  [`docs/runbook-college-updates.md`](docs/runbook-college-updates.md).

### Docs (`docs/`)

- Setup guides (`install-*.md`) are written for a first-timer starting from zero — keep both
  **bash** and **PowerShell** command variants where commands run locally.
- When infra changes, update the corresponding runbook in the same PR.

---

## Architecture decisions (ADRs)

Non-obvious decisions that had real alternatives and would otherwise get re-litigated are
recorded as ADRs in [`docs/decisions/`](docs/decisions/).

- Format: **Context → Decision → Alternatives considered → Consequences**.
- Status is one of `Proposed`, `Accepted`, `Superseded by NNNN`.
- Newest decision gets the next number; add a row to
  [`docs/decisions/README.md`](docs/decisions/README.md).

Write an ADR when you change hosting, auth, the sync model, or anything else future-you would
question. Don't write one for routine fixes.

---

## Secrets

**Never commit real credentials.** The following are already gitignored — keep it that way:

- `terraform.tfvars`, `*.auto.tfvars`, `*.tfstate*`, `.terraform/`
- `*.pem`, `*.key`, `certs/`
- `.env`, `.env.*` (the `*.env.example` templates are the exception and *should* be committed)
- `mcp.env`, `actual-http-api.env`

Secrets in scope include: Cloudflare/Hetzner API tokens, Google OAuth material, the Actual
server password **and** the budget's end-to-end-encryption password, R2 access keys, the MCP
bearer token, and the e-ink device token. If you ever commit one by accident, treat it as
compromised: rotate it, don't just `git rm`.

---

## Testing & verification

There's no CI-heavy test suite; verification is mostly manual and targeted:

- **Terraform:** `terraform fmt -check`, `terraform validate`, and review `terraform plan`
  output before applying. Never apply from an unreviewed plan.
- **Docker stack:** `docker compose config` to validate, `docker compose up -d` +
  `docker compose ps` to confirm services come up healthy.
- **College app:** `npm install && npm start`, then exercise the UI locally.
- **Runbooks:** the highest-value test here is *following your own runbook* end-to-end. An
  unexercised backup/restore runbook is a hope, not a backup (design §5.1).

Describe what you verified in the PR's "How was this tested?" section.
