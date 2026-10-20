# Installing the Actual HTTP REST API Sidecar

This walks you through deploying [`jhonderson/actual-http-api`](https://github.com/jhonderson/actual-http-api)
alongside the existing Actual Budget stack. The sidecar wraps `@actual-app/api` in a plain
REST interface with Swagger docs, so the Hub backend (Python/FastAPI) and any other REST
client can query budget data without embedding the Node library in-process.

**Prerequisites:** Complete `docs/install-actual.md` first. The sidecar depends on a running
`actual-server` container and the same Hetzner VPS + Cloudflare account.

**What you'll end up with:** A REST API at `https://actual-api.yourdomain.com` gated by
a static API key, with Swagger docs at `/api-docs/`, covering accounts, transactions,
budget months, categories, payees, schedules, and rules — full CRUD.

**Architecture:**
```
REST client / Hub backend
        │
        ▼
Cloudflare (TLS + WAF, no Access app)
        │
        ▼
Caddy (origin TLS termination)
        │
        ▼
actual-http-api:5007   ──── internal Docker network ────▶  actual-server:5006
  /mnt/data/actual-http-api   (own synced budget copy)
```

**Security model:** There is deliberately no Cloudflare Access application on this host.
Programmatic REST clients can't perform interactive browser SSO. The gate is the `API_KEY`
you set in `actual-http-api.env`. Cloudflare still provides TLS and WAF in front of it —
same pattern as the MCP server (ADR-0002).

---

## Part 1 — Provision the new Cloudflare resources

### 1a. Run terraform apply

The new resources (DNS record, origin cert) are already defined in `infra/terraform/main.tf`.
From `infra/terraform/`:

```bash
terraform plan
# Expect 4 new resources:
#   cloudflare_record.actual_api
#   tls_private_key.actual_api_origin
#   tls_cert_request.actual_api_origin
#   cloudflare_origin_ca_certificate.actual_api

terraform apply
# Type "yes" when prompted
```

### 1b. Capture the new origin certificate

**bash (macOS/Linux):**
```bash
terraform output -raw actual_api_origin_cert_pem > /tmp/actual-api-origin.pem
terraform output -raw actual_api_origin_key_pem  > /tmp/actual-api-origin.key
```

**PowerShell 7 (Windows):**
```powershell
terraform output -raw actual_api_origin_cert_pem > $env:TEMP\actual-api-origin.pem
terraform output -raw actual_api_origin_key_pem  > $env:TEMP\actual-api-origin.key
```

Note the API hostname for the steps below:

```bash
terraform output actual_api_host
# e.g. actual-api.yourdomain.com
```

---

## Part 2 — Configure secrets on the server

Set `$IP` if it isn't already (same as install-actual.md Part 6/7):

**bash:**
```bash
IP=$(terraform output -raw server_ipv4)
```

**PowerShell:**
```powershell
$IP = terraform output -raw server_ipv4
```

### 2a. Generate an API key

```bash
openssl rand -hex 32
# e.g. a3f8c21d9b4e7f60a1c5d8e2b9f3a6c4d7e1b8f5a2c9d6e3b0f7a4c1d8e5b2f9
```

Copy this value — you'll need it in the env file and whenever you call the API.

### 2b. Create the env file on the server

SSH into the server and create `actual-http-api.env` from the example:

```bash
ssh root@$IP
cd /opt/household-os/actual
cp actual-http-api.env.example actual-http-api.env
```

Fill in the values (the file is pre-commented with where each value comes from):

```bash
nano actual-http-api.env
```

```
API_KEY=<output from Step 2a>
ACTUAL_SERVER_PASSWORD=<your Actual server password from install-actual.md §10a>
ACTUAL_BUDGET_SYNC_ID=<your Sync ID from install-actual.md §10e>
ACTUAL_BUDGET_ENCRYPTION_PASSWORD=<your E2E password if enabled, else leave blank>
```

Save and exit (`Ctrl+O`, `Enter`, `Ctrl+X` in nano).

Exit the SSH session:
```bash
exit
```

---

## Part 3 — Copy the origin certificate to the server

**bash:**
```bash
scp /tmp/actual-api-origin.pem root@$IP:/opt/household-os/actual/certs/actual-api-origin.pem
scp /tmp/actual-api-origin.key root@$IP:/opt/household-os/actual/certs/actual-api-origin.key
ssh root@$IP 'chmod 600 /opt/household-os/actual/certs/actual-api-origin.key'
```

**PowerShell:**
```powershell
scp $env:TEMP\actual-api-origin.pem root@${IP}:/opt/household-os/actual/certs/actual-api-origin.pem
scp $env:TEMP\actual-api-origin.key root@${IP}:/opt/household-os/actual/certs/actual-api-origin.key
ssh root@$IP 'chmod 600 /opt/household-os/actual/certs/actual-api-origin.key'
```

---

## Part 4 — Update the Caddyfile

The Caddyfile ships with a `actual-api.example.com` placeholder. Replace it with your real
host:

**bash:**
```bash
ACTUAL_API_HOST=$(terraform output -raw actual_api_host)
ssh root@$IP "sed -i 's/actual-api.example.com/$ACTUAL_API_HOST/' /opt/household-os/actual/Caddyfile"
```

**PowerShell:**
```powershell
$actualApiHost = terraform output -raw actual_api_host
ssh root@$IP "sed -i 's/actual-api.example.com/$actualApiHost/' /opt/household-os/actual/Caddyfile"
```

Verify the Caddyfile looks right:
```bash
ssh root@$IP 'cat /opt/household-os/actual/Caddyfile'
# Should show actual-api.yourdomain.com in the new site block
```

---

## Part 5 — Deploy the sidecar

SSH in and pull the new image, then restart the stack to pick up the new service and the
updated Caddyfile:

```bash
ssh root@$IP
cd /opt/household-os/actual

# Pull the pinned image (26.10.0 — matches the version in docker-compose.yml)
docker compose pull actual-http-api

# Restart everything: Caddy picks up the new Caddyfile block,
# actual-http-api starts and syncs its own budget copy.
docker compose up -d

# Check all four services are Up:
docker compose ps
# Expected:
#   actual-server     Up (healthy)
#   actual-mcp        Up
#   actual-http-api   Up
#   caddy             Up
```

Watch the startup logs briefly:

```bash
docker compose logs --tail=30 actual-http-api
# Should show it connecting to actual-server:5006 and syncing the budget.
# Final line should be something like: "Server listening on port 5007"

docker compose logs --tail=20 caddy
# Should show a new TLS entry for actual-api.yourdomain.com — no errors.
```

Exit:
```bash
exit
```

---

## Part 6 — Verify

From your local machine (replace the placeholders with your real values):

```bash
API_HOST=$(terraform output -raw actual_api_host)
API_KEY=<your key from Step 2a>
SYNC_ID=<your Actual Sync ID>

# Health check — should return 200
curl -sf -H "X-Api-Key: $API_KEY" \
  "https://$API_HOST/v1/budgets/$SYNC_ID/months" | head -c 200
```

You should see a JSON array of budget month strings (e.g. `["2025-01","2025-02",...]`).

**Check the Swagger docs** (in a browser, not curl — it's an HTML page):

Open `https://actual-api.yourdomain.com/api-docs/` in a browser. You should see the full
interactive Swagger UI with all available endpoints. Authentication there uses the same
`X-Api-Key` header.

**Test that requests without the key are rejected:**

```bash
curl -sv "https://$API_HOST/v1/budgets/$SYNC_ID/months" 2>&1 | grep "< HTTP"
# Should print: < HTTP/2 401
```

---

## Version pinning and upgrades

The `docker-compose.yml` pins `actual-http-api` to a specific version tag (`26.10.0`).
The version number tracks Actual Budget's release — keep it in sync with `actual-server`:

```bash
# Check what actual-server is currently running:
ssh root@$IP "docker inspect actualbudget/actual-server:latest | grep -i 'org.opencontainers.image.version'"

# To upgrade actual-http-api, update the tag in docker-compose.yml and redeploy:
# 1. Edit infra/actual/docker-compose.yml: change 26.10.0 to the new version
# 2. scp the updated file to the server
# 3. docker compose pull actual-http-api && docker compose up -d actual-http-api
```

Check the [actual-http-api releases](https://github.com/jhonderson/actual-http-api/releases)
page before upgrading — the changelog notes any breaking API changes.

---

## Rotating the API key

If the key is ever compromised:

```bash
# Generate a new key:
openssl rand -hex 32

# Update the env file on the server:
ssh root@$IP
nano /opt/household-os/actual/actual-http-api.env
# Replace API_KEY= with the new value, save

# Restart the container to pick up the new key:
docker compose -f /opt/household-os/actual/docker-compose.yml restart actual-http-api
exit

# Update any clients that use the old key (Hub backend env, etc.)
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `401 Unauthorized` on all requests | Missing or wrong API key | Check `X-Api-Key` header matches `API_KEY` in `actual-http-api.env`; restart the container after changing the env file |
| `502 Bad Gateway` from Caddy | `actual-http-api` container not running or still starting | `docker compose logs actual-http-api`; check it connected to `actual-server:5006` |
| Cloudflare 526 / cert error | Origin cert not in place or wrong hostname | Confirm `certs/actual-api-origin.pem` exists on the server and the Caddyfile hostname matches `terraform output actual_api_host` |
| Container starts but budget data is empty | First sync still running | Wait 30–60 seconds and retry — `@actual-app/api` downloads a full budget copy on first run |
| `ECONNREFUSED http://actual-server:5006` | `actual-server` not running, or `actual-http-api` started before it | `docker compose up -d actual-server` first; `depends_on` in `docker-compose.yml` should prevent this but `restart: unless-stopped` handles race conditions |
| Swagger UI at `/api-docs/` returns 404 | Older image version | Confirm image is `26.6.1` or later: `docker compose images actual-http-api` |
| Every budget request returns `500 "Unknown error while interacting with Actual Api"` | `actual-http-api` is older than `actual-server`: its bundled `@actual-app/api` can't open a budget written by a newer Actual | Bump the image tag to match the server's version (`docker compose exec actual-server node -e "console.log(require('./package.json').version)"` or Settings → About in Actual), then `docker compose pull actual-http-api && docker compose up -d actual-http-api` |
| Experimental endpoints return `501 Not Implemented` | `EXPERIMENTAL_OPERATIONS_ENABLED=false` (intentional) | This is expected. If you need these endpoints, set `EXPERIMENTAL_OPERATIONS_ENABLED=true` in `actual-http-api.env` and restart — understand the risk first (they use Actual internals that may change without notice) |
| Budget data is stale after a transaction | Sync runs on each API call | If data looks stale, check `docker compose logs actual-http-api` for sync errors; the most common cause is a wrong `ACTUAL_BUDGET_SYNC_ID` |
