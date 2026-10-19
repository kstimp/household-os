# Runbook: Hub backend deployment & updates

**Stack:** Python/FastAPI app at `/opt/household-os/hub` (built as the `hub` container in `/opt/household-os/actual/docker-compose.yml`)
**Served at:** `https://stimpert.haus/api/*` — the apex, routed by Caddy, behind the apex's Cloudflare Access app
**Data:** `/mnt/data/hub/hub.db` (SQLite) — a cache of Actual plus worker heartbeats; safe to delete, rebuilt on the next worker run
**Depends on:** the `actual-http-api` sidecar ([`install-actual-http-api.md`](install-actual-http-api.md))
**Verify:** load `https://stimpert.haus/api/health` in a signed-in browser, or from the VPS see §3 (the container has no host port)

Why Python and why this shape: [ADR-0007](decisions/0007-hub-backend-python.md).

```
browser ──▶ Cloudflare Access ──▶ Caddy (apex)
                                   ├─ /api/*  ──▶ hub:8000 ──GET──▶ actual-http-api:5007 ──▶ actual-server:5006
                                   └─ else    ──▶ /srv/landing (static page)
```

**Endpoints**

| Path | What |
|---|---|
| `GET /api/health` | Per-worker heartbeat: `last_success_at`, `last_error`, `stale` (no success in 2 intervals). `status` is `ok` or `degraded`. |
| `GET /api/budget/kpis` | Latest budget KPI snapshot + the finance worker's heartbeat. `503` until the first successful run. |
| `GET /api/docs` | Swagger UI. |

---

## 1 — Initial deployment

**Prerequisite:** the landing page is deployed (`runbook-landing-updates.md`) and
`actual-http-api` is up (`install-actual-http-api.md`). No Terraform changes — the Hub reuses
the apex's DNS record, certificate and Access app.

### 1a. Copy files to the VPS

**bash (macOS/Linux):**
```bash
IP=$(cd infra/terraform && terraform output -raw server_ipv4)
ssh root@$IP "mkdir -p /opt/household-os/hub"
scp -r infra/hub/* root@$IP:/opt/household-os/hub/
scp infra/actual/docker-compose.yml infra/actual/Caddyfile infra/actual/hub.env.example root@$IP:/opt/household-os/actual/
```

**PowerShell 7 (Windows):**
```powershell
$IP = terraform -chdir=infra/terraform output -raw server_ipv4
ssh root@$IP "mkdir -p /opt/household-os/hub"
scp -r infra\hub\* root@${IP}:/opt/household-os/hub/
scp infra\actual\docker-compose.yml root@${IP}:/opt/household-os/actual/docker-compose.yml
scp infra\actual\Caddyfile root@${IP}:/opt/household-os/actual/Caddyfile
scp infra\actual\hub.env.example root@${IP}:/opt/household-os/actual/hub.env.example
```

> **The Caddyfile you just copied has placeholder hostnames.** Re-apply your real hostnames
> exactly as you did when first deploying each site (e.g. `runbook-landing-updates.md` §1c
> for the apex, `install-actual-http-api.md` Part 4 for the API host), or keep a copy of the
> live Caddyfile and add only the `handle /api/*` block to its apex site by hand.

### 1b. Create the env file

```bash
ssh root@$IP
cd /opt/household-os/actual
cp hub.env.example hub.env
chmod 600 hub.env
nano hub.env
```

```
ACTUAL_API_KEY=<same value as API_KEY in actual-http-api.env>
ACTUAL_BUDGET_SYNC_ID=<your Sync ID — same as in actual-http-api.env>
ACTUAL_BUDGET_ENCRYPTION_PASSWORD=<only if E2E encryption is on, else blank>
```

If you skip this step the Hub still starts; the finance worker is disabled and
`/api/health` reports `"finance": {"configured": false}`.

### 1c. Build and start

```bash
mkdir -p /mnt/data/hub
cd /opt/household-os/actual
docker compose build hub
docker compose up -d hub caddy     # caddy picks up the new /api route
docker compose ps hub
docker compose logs --tail=20 hub
# Expect: "Application startup complete." then "hub.worker finance ok"
```

Reload `https://stimpert.haus`: the Money card shows the four figures and "Updated N min ago".

---

## 2 — Applying updates

**bash (macOS/Linux):**
```bash
IP=$(cd infra/terraform && terraform output -raw server_ipv4)
scp -r infra/hub/* root@$IP:/opt/household-os/hub/
ssh root@$IP "cd /opt/household-os/actual && docker compose build hub && docker compose up -d hub"
```

**PowerShell 7 (Windows):**
```powershell
$IP = terraform -chdir=infra/terraform output -raw server_ipv4
scp -r infra\hub\* root@${IP}:/opt/household-os/hub/
ssh root@$IP "cd /opt/household-os/actual && docker compose build hub && docker compose up -d hub"
```

Schema changes are `CREATE TABLE IF NOT EXISTS` today. Because the database is a rebuildable
cache, the escape hatch for a bad schema is: stop the hub, delete `/mnt/data/hub/hub.db*`,
start it again.

---

## 3 — Verify, troubleshoot, rollback

### Verify (on the VPS)
```bash
cd /opt/household-os/actual
docker compose exec hub python -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8000/api/health').read().decode())"
```
Unauthenticated from outside, `curl -sI https://stimpert.haus/api/health` should 302 to the
Google login (Cloudflare Access), not return JSON.

### Card footer states

| Footer | Meaning | Look at |
|---|---|---|
| Updated N min ago | Healthy. | — |
| Stale — updated N h ago | Finance worker has not succeeded for 2+ intervals; the page shows the last good snapshot. | `docker compose logs hub` and `/api/health` → `last_error` (usually wrong key/Sync ID, or `actual-http-api` down) |
| Budget figures unavailable | No snapshot yet (first run pending, `hub.env` missing) or the hub is down. | `docker compose ps hub`, `/api/health` |

### Rollback
1. Revert the git commit locally.
2. Re-run §2. The database needs no restore (it's a cache). To remove the Hub entirely,
   also remove the `hub` service and the `handle /api/*` block, re-copy
   `docker-compose.yml`/`Caddyfile`, and `docker compose up -d --remove-orphans`.

### Backups
Not included in `backup.sh` on purpose: `hub.db` holds only data derived from Actual. When the
Hub gains data it owns, add Litestream (design §5.1) in the same change.

---

## 4 — Local development

**bash (macOS/Linux):**
```bash
cd infra/hub
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
pytest
# Run against a real/forwarded actual-http-api:
ACTUAL_API_URL=http://localhost:5007/v1 ACTUAL_API_KEY=... ACTUAL_BUDGET_SYNC_ID=... \
  uvicorn hub.main:create_app --factory --reload
```

**PowerShell 7 (Windows):**
```powershell
cd infra\hub
python -m venv .venv; .\.venv\Scripts\Activate.ps1
pip install -r requirements-dev.txt
pytest
$env:ACTUAL_API_URL="http://localhost:5007/v1"; $env:ACTUAL_API_KEY="..."; $env:ACTUAL_BUDGET_SYNC_ID="..."
uvicorn hub.main:create_app --factory --reload
```

### KPI definitions

| Figure | Definition |
|---|---|
| Uncategorized | Transactions in on-budget accounts with no category, excluding transfers between two on-budget accounts (matches Actual's "uncategorized" view; split parents are judged by their children). |
| Overspent | Visible expense categories with a negative balance in the current month (UTC). |
| Unreconciled | Transactions not yet reconciled in open on-budget accounts. |
| Reconciled | Days since the newest reconciled transaction in the stalest open on-budget account; "Never" if one has none. Proxy for Actual's `last_reconciled`, which the API doesn't expose. |
