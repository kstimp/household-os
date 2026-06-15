# AI budget access — the MCP budget server

This document evaluates and deploys an **MCP server** in front of Actual Budget so
you and your family can **interrogate and manage** the budget through an AI
assistant (Claude.ai / Claude Desktop connectors) in natural language.

It assumes Actual is already running per [`install-actual.md`](install-actual.md).
The architecture decision and its trade-offs live in
[ADR-0002](decisions/0002-mcp-budget-server.md) — read that first; this doc is the
evaluation detail and the deploy runbook.

---

## What it is, and how it fits

An MCP server is a small Node process that wraps Actual's `@actual-app/api`
library and exposes its operations as **tools** an AI assistant can call. It
maintains its own full **synced local copy** of the budget (the same mechanism
the planned finance worker uses, design §2.4) and connects to Actual exactly the
way the finance worker will: over the **internal Docker network** at
`http://actual-server:5006`, **bypassing Cloudflare Access**.

So infrastructurally it's a near drop-in: a sibling container next to
`actual-server` and `caddy`, reusing secrets we already manage on the VPS.

### Relationship to the (planned) finance worker

| | Finance worker (planned, design §2.4) | MCP server (this doc) |
|---|---|---|
| Driver | Cron / automated | You & family, conversationally via AI |
| Direction | **Read-only** mirror | **Read + write** |
| Purpose | Dashboard widgets, overspend alerts | Interrogate *and manage* the budget |

They are siblings, not substitutes — you'll likely still want the worker later
for silent dashboard mirroring and alerts. The MCP server is the first thing to
cross the design §2.6 "no write-back" line, which is why it needed ADR-0002.

## Project chosen: `agigante80/actual-mcp-server`

Picked as the **most capable** option for a remote, write-enabled deployment.

| | agigante80 (chosen) | s-stefanov (runner-up) |
|---|---|---|
| Tools | **71 (~84% API coverage)** | core read set + CRUD |
| Write | full suite, always on | behind `--enable-write` |
| HTTP/remote | native (`--http`, Docker-first) | bolted-on (`--sse`) |
| Auth | Bearer **+ OIDC/JWT + per-user ACL** | Bearer only |
| Ops | connection pooling, session mgmt, retry/backoff | basic |
| Community | ~19★, single maintainer | ~160★ |

The community-size gap is a real supply-chain signal (this code holds your Actual
password). It's the documented fallback if maintainer trust becomes a concern.

### Capabilities it adds

- **Interrogate (read):** accounts, balances, transaction search/filter,
  spending-by-category, monthly summaries, balance-history trends, budget review,
  plus ActualQL-powered aggregation tools (summarized results, not raw dumps).
- **Manage (write):** create / update / delete / import transactions, recategorize,
  create payees and rules, set budget amounts/targets/transfers/carryover/holds,
  open/close accounts, trigger bank sync.

> ⚠️ There is **no tool-level read-only mode** — all 71 tools are live. Your
> guardrails are network isolation + the auth token, plus Actual's own undo and
> the §5.1 backups for recovery. (To stay strictly read-only, deploy s-stefanov
> *without* `--enable-write` instead.)

---

## Security model & threat model

The budget host is gated by Cloudflare Access (Google SSO). **This host is not** —
Access blocks non-browser MCP clients (install §10f). The gate here is the MCP
server's own auth. Defense in depth, outermost to innermost:

1. **Cloudflare proxy (orange cloud).** Hides the origin IP, terminates public
   TLS, and provides WAF + rate-limiting in front of the token. (Terraform sets
   `proxied = true` and creates an Origin cert; **no** Access app on this host.)
2. **Bearer token (v1 gate).** A 256-bit shared secret (`openssl rand -hex 32`)
   in `MCP_SSE_AUTHORIZATION`; clients send `Authorization: Bearer <token>`.
3. **Network isolation.** The container is not published to the host (no `ports:`);
   only Caddy reaches it, and its only outbound need is `actual-server`.
4. **Secrets stay on the VPS** (`mcp.env`, gitignored), never on family laptops —
   consistent with design §4.4.

**Residual risks (accepted in ADR-0002):** a write-capable financial endpoint is
internet-reachable behind a *shared* token rather than per-person SSO; and
third-party code holds the Actual password (and the E2E key if encryption is on).

### Hardening upgrade — OIDC instead of a shared Bearer token

For per-user identity (and per-user budget ACLs), switch from the static token to
OIDC/JWT in `mcp.env`:

```
AUTH_PROVIDER=oidc
OIDC_ISSUER=https://<your-issuer>
OIDC_RESOURCE=<expected-jwt-aud>
AUTH_BUDGET_ACL=<user→budget map>
# remove MCP_SSE_AUTHORIZATION once OIDC is in place
```

Optional extra layer: a Cloudflare Access **service token** in front (sends
`CF-Access-Client-Id` / `CF-Access-Client-Secret` headers) — only if your MCP
client can attach custom headers.

---

## Deploy runbook

Prerequisite: Actual is up (install doc Parts 1–11), and you know your Actual
**server password**, **Sync ID**, and (if enabled) **E2E password**.

### 1. Provision the MCP host (Terraform)

The Terraform in `infra/terraform/` already includes the `mcp-budget` DNS record
and its Origin cert (no Access app — see ADR-0002). From `infra/terraform/`:

**bash:**
```bash
terraform plan    # review: 1 new DNS record + 1 new origin cert, NO new Access app
terraform apply

# Export the MCP host's origin cert/key (note the mcp_* outputs):
terraform output -raw mcp_origin_cert_pem > /tmp/mcp-origin.pem
terraform output -raw mcp_origin_key_pem  > /tmp/mcp-origin.key
MCP_HOST=$(terraform output -raw mcp_host)
```

**PowerShell:**
```powershell
terraform plan    # review: 1 new DNS record + 1 new origin cert, NO new Access app
terraform apply

# Export the MCP host's origin cert/key (note the mcp_* outputs):
terraform output -raw mcp_origin_cert_pem | Out-File -Encoding ascii "$env:TEMP\mcp-origin.pem"
terraform output -raw mcp_origin_key_pem  | Out-File -Encoding ascii "$env:TEMP\mcp-origin.key"
$MCP_HOST = (terraform output -raw mcp_host).Trim()
```

### 2. Ship cert + config to the box

**bash:**
```bash
IP=$(terraform output -raw server_ipv4)

# Origin cert/key for the MCP host (alongside the budget cert already there):
scp /tmp/mcp-origin.pem root@$IP:/opt/household-os/actual/certs/mcp-origin.pem
scp /tmp/mcp-origin.key root@$IP:/opt/household-os/actual/certs/mcp-origin.key
ssh root@$IP 'chmod 600 /opt/household-os/actual/certs/mcp-origin.key'

# Re-copy the updated compose + Caddyfile (now include the actual-mcp service/site):
scp ../actual/docker-compose.yml ../actual/Caddyfile ../actual/mcp.env.example \
    root@$IP:/opt/household-os/actual/

# Fill the Caddyfile placeholder for the MCP host:
ssh root@$IP "sed -i 's/mcp-budget.example.com/$MCP_HOST/' /opt/household-os/actual/Caddyfile"
```

**PowerShell:**
```powershell
$IP = (terraform output -raw server_ipv4).Trim()

# Origin cert/key for the MCP host (alongside the budget cert already there):
scp "$env:TEMP\mcp-origin.pem" root@${IP}:/opt/household-os/actual/certs/mcp-origin.pem
scp "$env:TEMP\mcp-origin.key" root@${IP}:/opt/household-os/actual/certs/mcp-origin.key
ssh root@$IP 'chmod 600 /opt/household-os/actual/certs/mcp-origin.key'

# Re-copy the updated compose + Caddyfile (now include the actual-mcp service/site):
scp ..\actual\docker-compose.yml ..\actual\Caddyfile ..\actual\mcp.env.example `
    root@${IP}:/opt/household-os/actual/

# Fill the Caddyfile placeholder for the MCP host:
ssh root@$IP "sed -i 's/mcp-budget.example.com/$MCP_HOST/' /opt/household-os/actual/Caddyfile"
```

### 3. Create the secrets file

*(Steps 3–4 run inside an interactive SSH session on the Linux server — no PowerShell translation needed. If `$IP` is not set from step 2, re-assign it first: PowerShell: `$IP = (terraform output -raw server_ipv4).Trim()`)*

```bash
ssh root@$IP
cd /opt/household-os/actual
cp mcp.env.example mcp.env
# Generate the Bearer token:
echo "MCP_SSE_AUTHORIZATION=$(openssl rand -hex 32)" >> mcp.env
nano mcp.env   # fill ACTUAL_PASSWORD, ACTUAL_BUDGET_SYNC_ID, (ACTUAL_BUDGET_PASSWORD if E2E)
chmod 600 mcp.env
```

### 4. Start it

```bash
mkdir -p /mnt/data/actual-mcp        # persistent synced-budget copy on the data volume
docker compose up -d                 # brings up actual-mcp + reloads caddy
docker compose ps                    # actual-server, actual-mcp, caddy all Up
docker compose logs --tail=40 actual-mcp   # should connect to Actual and download the budget
exit
```

### 5. Connect your AI client

Add a **custom connector** in Claude.ai / Claude Desktop pointing at:

- **URL:** `https://<mcp_host>/http`  (the `MCP_HTTP_PATH` default is `/http`)
- **Auth header:** `Authorization: Bearer <the token from mcp.env>`

Then verify with a read first ("list my accounts and this month's category
balances") before trying any write.

### 6. Smoke test & guardrails

- **Auth works:** a request without the Bearer token is rejected.
- **Read path:** account/category queries return real data.
- **Write path (deliberate):** make one small edit ("add a $1 test transaction to
  X"), confirm it appears in the Actual web app, then delete it — exercising the
  write path *and* your ability to undo via Actual.
- **Backups:** confirm the §5.1 weekly Actual export still runs — it's your
  recovery path for an unwanted AI write.

---

## Operations

- **Pin the image.** The compose currently tracks `:latest`; once you've verified
  a version, pin the tag (e.g. `:v0.7.3`) so an upstream change can't surprise a
  process holding your financial credentials.
- **Rotate the token** by editing `mcp.env` and `docker compose up -d actual-mcp`;
  update the connector. Do this if a device with the token is lost.
- **Logs:** `docker compose logs -f actual-mcp`. Set `MCP_BRIDGE_STORE_LOGS=true`
  in `mcp.env` for file logging if you want persistence.
- **Upgrades:** `docker compose pull actual-mcp && docker compose up -d actual-mcp`
  (after reviewing the release) — re-run the smoke test afterward.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Client gets the Cloudflare Access login page / HTML instead of MCP JSON | An Access app got attached to the MCP host | This host must have **no** Access application (ADR-0002). Remove it; keep only the proxied DNS record. |
| 401 / unauthorized | Token mismatch | Confirm the connector's `Authorization: Bearer` matches `MCP_SSE_AUTHORIZATION` in `mcp.env`; restart the container after edits. |
| Cloudflare 526 / cert error | SSL not Full (strict), or wrong origin cert on the box | Set zone SSL to **Full (strict)**; re-copy `mcp-origin.pem`/`.key` from `terraform output`. |
| `actual-mcp` can't reach Actual | Pointed at the public URL | Must be `http://actual-server:5006` (internal network), not the public domain. |
| Empty/locked budget data | Missing E2E password | If Actual E2E is on (§10c), set `ACTUAL_BUDGET_PASSWORD` in `mcp.env`. |
