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
an interactive Access app blocks non-browser MCP clients (install §10f). The gate
here is the MCP server's own auth. Defense in depth, outermost to innermost:

1. **Cloudflare proxy (orange cloud).** Hides the origin IP, terminates public
   TLS, and provides WAF + rate-limiting in front of the token. (Terraform sets
   `proxied = true` and creates an Origin cert.)
2. **The MCP server's own auth gate — per-user Google OIDC/JWT** (ADR-0004).
   `AUTH_PROVIDER=oidc`, `OIDC_ISSUER=https://accounts.google.com`, JWKS-validated,
   per-email `AUTH_BUDGET_ACL`. All clients authenticate via Google OAuth 2.1 PKCE.
   The interim Bearer token (`MCP_SSE_AUTHORIZATION`) is kept set until OIDC is
   verified end-to-end, then removed (see "Auth" and §7 below).
3. **(Optional) Cloudflare Access service token.** A non-interactive header gate
   at the edge (`CF-Access-Client-Id` / `CF-Access-Client-Secret`) in front of (2),
   added by `var.enable_mcp_access_service_token` (ADR-0003). Off by default.
4. **Network isolation.** The container is not published to the host (no `ports:`);
   only Caddy reaches it, and its only outbound need is `actual-server`.
5. **Secrets stay on the VPS** (`mcp.env`, gitignored), never on family laptops —
   consistent with design §4.4.

**Residual risks (accepted in ADR-0002, narrowed by ADR-0004):** a write-capable
financial endpoint is internet-reachable; third-party code holds the Actual password
(and the E2E key if encryption is on). Under OIDC (ADR-0004), per-user Google identity
+ short-lived tokens + `AUTH_BUDGET_ACL` replace the anonymous shared Bearer token.
Residual: the family allowlist now lives in two places (CF Access for Actual, `AUTH_BUDGET_ACL`
for MCP) — keep them in sync when adding users.

### Auth: per-user Google OIDC/JWT — ADR-0004

The gate is **per-user Google OAuth 2.0 / OIDC**, using
**`OIDC_ISSUER=https://accounts.google.com`** so the existing Google identities (already
used in CF Zero Trust) are the authoritative identity source — no new always-on identity
provider. The server validates every request's JWT against Google's JWKS: signature +
issuer + audience on every call. Per-email `AUTH_BUDGET_ACL` replaces the anonymous
shared token with per-user scoping.

(CF Access as the OIDC issuer was attempted in ADR-0003 and found permanently unworkable.
Google resolves all three blockers from that attempt — see ADR-0003 for details.)

Set in `mcp.env` (var names from agigante80/actual-mcp-server v0.7.11 `docs/CONFIGURATION.md`):

```
AUTH_PROVIDER=oidc
OIDC_ISSUER=https://accounts.google.com             # JWKS at https://www.googleapis.com/oauth2/v3/certs
OIDC_RESOURCE=<google-oauth-client-id>              # Google ID token `aud` = your OAuth client ID
OIDC_ACCEPTED_AUDIENCES=<google-oauth-client-id>   # repeat client ID here (both form the accepted aud set)
OIDC_SCOPES=openid email                            # NOT empty — Google emits the `scope` claim
AUTH_BUDGET_ACL={"you@gmail.com":["<budget-sync-id>"]}  # principal(email|sub|group:<name>) → [sync ids]; ["*"]=all
# keep MCP_SSE_AUTHORIZATION set during the cutover; remove it only after OIDC verifies
```

> **`AUTH_PROVIDER=oidc` is a hard flip.** Setting it completely disables the Bearer
> token server-wide — there is no dual-auth mode. All clients must complete the Google
> OAuth flow once this is set. Keep `MCP_SSE_AUTHORIZATION` in `mcp.env` (but NOT in the
> env as `AUTH_PROVIDER=oidc` disables it) until OIDC is verified end-to-end.

> **Supply-chain note.** Before removing the Bearer token, run the OIDC acceptance
> criteria (§7d) — especially the tampered-signature and wrong-issuer/audience negatives —
> to confirm JWT validation is real, not cosmetic.

### OIDC cutover — acceptance criteria & sequence (ADR-0004)

This is the *what*; the executable step-by-step (commands, probes, rollback) is the
**[OIDC cutover deployment runbook](#7-oidc-cutover--deployment-runbook-adr-0004)**
(Deploy runbook §7). Run with **both** Bearer and OIDC env vars present in `mcp.env`
but `AUTH_PROVIDER=oidc` active (Bearer is disabled server-side). All must pass
**before** removing `MCP_SSE_AUTHORIZATION` from `mcp.env`:

1. **Positive (Google ID token):** a valid Google ID token from the configured OAuth
   client succeeds on a read tool ("list accounts"). *(Gating test — if this returns 401
   with a JWT parse error in the logs, Claude is sending an opaque access token instead
   of the JWT ID token; see ADR-0004 Consequences.)*
2. **No token → 401.**
3. **Wrong issuer → rejected** (well-formed JWT from a different issuer, e.g. a
   self-signed token).
4. **Wrong audience → rejected** (Google ID token with a different client ID in `aud`).
5. **Expired → rejected** (proves expiry is checked).
6. **Tampered signature → rejected** (proves signature validation is real — the key
   supply-chain test).
7. **ACL: unauthorized email → 403** (user whose email is not in `AUTH_BUDGET_ACL`).
8. **Write path works** for an authorized user (add a $1 test txn, confirm in Actual,
   delete — same smoke test as the deploy runbook).
9. **Hard flip confirmed:** the old `MCP_SSE_AUTHORIZATION` Bearer value → 401 (proves
   the Bearer path is disabled once `AUTH_PROVIDER=oidc` is set; cutover is not
   reversible by env-var toggle alone — see rollback in §7f).

Then cut over: remove `MCP_SSE_AUTHORIZATION` from `mcp.env` →
`docker compose up -d actual-mcp` → re-verify (1) positive and (2) no-token.

---

## Deploy runbook

Prerequisite: Actual is up (install doc Parts 1–11), and you know your Actual
**server password**, **Sync ID**, and (if enabled) **E2E password**.

### 1. Provision the MCP host (Terraform)

The Terraform in `infra/terraform/` already includes the `mcp-budget` DNS record
and its Origin cert (no Access app by default — see ADR-0002). The optional ADR-0003
service-token Access layer is off unless you set `enable_mcp_access_service_token =
true` (then the plan also adds an Access app + service token on this host). From
`infra/terraform/`:

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

The MCP endpoint is `https://<mcp_host>/http` (the default `MCP_HTTP_PATH` is `/http`).
All three clients authenticate via **Google OAuth 2.0** using the credentials from your
Google Cloud Console OAuth client (see §7a for how to create it). Because
`AUTH_PROVIDER=oidc` disables Bearer server-wide, there is no static-token option once
OIDC is active — all clients must complete the Google OAuth flow.

#### Claude.ai web (syncs automatically to Claude mobile)

Settings → Integrations → Add custom integration → Advanced Settings:

- **Name:** Budget
- **URL:** `https://<mcp_host>/http`
- **Authorization URL:** `https://accounts.google.com/o/oauth2/v2/auth`
- **Token URL:** `https://oauth2.googleapis.com/token`
- **Client ID:** `<google-oauth-client-id>`
- **Client Secret:** `<google-oauth-client-secret>`
- **Scopes:** `openid email`

The connector syncs automatically to the Claude iOS/Android app. Verify with "list
my accounts and this month's balances."

> **Known issue (claude.ai bug #46140):** The OAuth flow may complete but the token
> is not forwarded to the MCP server on some requests. Check if the issue is resolved
> before relying on this; retry the auth flow if requests return 401 unexpectedly.

#### Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) or
`%APPDATA%\Claude\claude_desktop_config.json` (Windows):

```json
{
  "mcpServers": {
    "budget": {
      "url": "https://<mcp_host>/http",
      "oauth": {
        "clientId": "<google-oauth-client-id>",
        "clientSecret": "<google-oauth-client-secret>",
        "authorizationUrl": "https://accounts.google.com/o/oauth2/v2/auth",
        "tokenUrl": "https://oauth2.googleapis.com/token",
        "scopes": ["openid", "email"]
      }
    }
  }
}
```

Restart Claude Desktop after saving. Verify with "list my accounts."

> **Schema note:** Claude Desktop's remote-MCP config evolves. If the `oauth` key
> structure above doesn't work, check the current format at docs.anthropic.com under
> MCP → Connecting to remote servers.

#### Claude Code

```bash
claude mcp add budget --transport http "https://<mcp_host>/http"
# Claude Code will prompt for OAuth authentication on first use
```

#### Family members (non-technical users)

A spouse or other family member uses the same **claude.ai web** steps above with
their own Google account. Add their email to `AUTH_BUDGET_ACL` in `mcp.env` before
they connect.

**Other AI UIs that support custom remote MCP:**
- **ChatGPT (Plus/Pro/Team):** Settings → Connectors → Create; supports remote MCP
  with OAuth. Very user-friendly web and mobile apps.
- **Open WebUI** (self-hosted): Admin Settings → External Tools → Add; web UI-driven.
- **Gemini:** Gemini CLI (`gemini-cli mcp add`) supports remote MCP. The consumer
  gemini.google.com web/mobile apps do **not** support custom remote MCP servers.

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

### 7. OIDC cutover — deployment runbook (ADR-0004)

Migrate the gate from the shared Bearer token to per-user Google OIDC. Run this
**after** the Bearer deployment (steps 1–6) is live. Steps below are tagged
**(workstation)** — run on your local machine — or **(on the box)** — run inside the
SSH session. `$IP` / `$MCP_HOST` come from `terraform output` (step 2).

> **Hard flip warning.** `AUTH_PROVIDER=oidc` disables Bearer token auth server-wide.
> There is no dual-auth mode. Once set, all clients must use OAuth. Rollback requires
> editing `mcp.env` and restarting the container (see §7f).

**7a. Create the Google OAuth 2.0 client — (workstation, one-time).**

1. Go to [console.cloud.google.com](https://console.cloud.google.com) → APIs & Services
   → Credentials → + Create Credentials → OAuth 2.0 Client ID
2. Application type: **Web application**; Name: `Household Budget MCP`
3. Add **Authorized redirect URIs** (add all of these; exact URIs vary by Claude
   client version — add `https://claude.ai/oauth-callback` and `http://localhost` as
   a minimum, then extend from client docs):
   - `https://claude.ai/oauth-callback`
   - `https://claude.ai/callback`
   - `http://localhost`
4. Click **Create**. Copy the **Client ID** and **Client Secret**.
5. Configure the OAuth consent screen: **APIs & Services → OAuth consent screen →
   Data Access → Add or remove scopes** — add `openid` and `email`. Under
   **Audience**, add your Gmail as a test user if the app is in Testing mode.

**7b. Add the OIDC block to `mcp.env` — (on the box).**

```bash
ssh root@$IP
cd /opt/household-os/actual
cat >> mcp.env <<'OIDC'
AUTH_PROVIDER=oidc
OIDC_ISSUER=https://accounts.google.com
OIDC_RESOURCE=<google-oauth-client-id>
OIDC_ACCEPTED_AUDIENCES=<google-oauth-client-id>
OIDC_SCOPES=openid email
AUTH_BUDGET_ACL={"you@gmail.com":["<budget-sync-id>"]}
OIDC
nano mcp.env          # fill the <...> placeholders; leave MCP_SSE_AUTHORIZATION in place
docker compose up -d actual-mcp
docker compose logs --tail=40 actual-mcp   # should report OIDC/JWKS init with Google issuer, no errors
exit
```

**7c. Obtain a Google ID token for testing — (workstation).** Complete the OAuth flow
with your client credentials and extract the `id_token` from the token response.
Options:
- **gcloud:** `gcloud auth print-identity-token` (if Google Cloud SDK is installed
  and authenticated with the same Google account)
- **Postman / Insomnia:** create an OAuth 2.0 request with your client ID/secret and
  `openid email` scopes; copy the `id_token` from the JSON response
- **curl:** exchange an authorization code from the browser flow manually

```bash
# gcloud method (simplest if already installed):
JWT=$(gcloud auth print-identity-token)
```

```powershell
# gcloud method (PowerShell):
$JWT = gcloud auth print-identity-token
```

> **Note:** `gcloud auth print-identity-token` issues a token for the gcloud project's
> audience, not your OAuth client ID. To test with the exact audience the MCP server
> expects, use a token obtained via Postman/curl with your client credentials.

**7d. Run the acceptance criteria — (workstation).** Define a probe that POSTs a
standard MCP `tools/list`, then call it per test.

**bash:**
```bash
probe() {  # usage: probe "<Authorization header value>"
  curl -s -o /dev/null -w '%{http_code}\n' \
    -X POST "https://$MCP_HOST/http" \
    -H 'Content-Type: application/json' \
    ${1:+-H "Authorization: $1"} \
    --data '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
}

probe "Bearer $JWT"                                          # 1. Positive (ID token) → 200
                                                             #    IF 401: check server logs — JWT parse error =
                                                             #    opaque access token; see ADR-0004 Consequences
probe ""                                                     # 2. No token → 401
probe "Bearer eyJhbGciOiJSUzI1NiJ9.eyJpc3MiOiJodHRwczovL2V4YW1wbGUuY29tIn0.fake"  # 3. Wrong issuer → 401
probe "Bearer $(echo "$JWT" | python3 -c "
import sys, json, base64
parts = sys.stdin.read().strip().split('.')
payload = json.loads(base64.urlsafe_b64decode(parts[1] + '=='))
payload['aud'] = 'wrong-client-id'
parts[1] = base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip('=')
print('.'.join(parts))")"                                   # 4. Wrong audience → 401
# 5. Expired: reuse a captured $JWT after its 1-hour expiry window → 401
probe "Bearer $(printf '%s' "$JWT" | sed 's/.$/X/')"        # 6. Tampered signature → 401
# 7. ACL: with a second Google account not in AUTH_BUDGET_ACL, attempt a read → 403
```

**PowerShell:**
```powershell
function Probe([string]$Auth) {  # usage: Probe "Bearer <token>"  ('' for no token)
  $headers = @{ 'Content-Type' = 'application/json' }
  if ($Auth) { $headers['Authorization'] = $Auth }
  try {
    (Invoke-WebRequest -Uri "https://$MCP_HOST/http" -Method Post -Headers $headers `
       -Body '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' -UseBasicParsing).StatusCode
  } catch { $_.Exception.Response.StatusCode.value__ }   # 401/403 land here
}

Probe "Bearer $JWT"                                          # 1. Positive (ID token) → 200
Probe ""                                                     # 2. No token → 401
# 3–7: obtain tokens with wrong issuer, wrong aud, expired, tampered sig for the negative tests
Probe ("Bearer " + $JWT.Substring(0, $JWT.Length - 1) + "X")  # 6. Tampered signature → 401
```

**7e. Write-path check — (AI client).**

- **8.** With the AI client connector configured (§5 above), add a $1 test transaction,
  confirm it appears in the Actual web app, then delete it — same smoke test as step 6.

**7f. Hard-flip confirmation + cut over — (workstation + box).**

- **9.** Confirm the Bearer path is now disabled:

  **bash:** `probe "Bearer $BEARER"` (where `$BEARER` is the `MCP_SSE_AUTHORIZATION` value) → **401**

  **PowerShell:** `Probe "Bearer $BEARER"` → **401**

  A 401 here is expected and correct — it proves the hard flip is in effect.

Once criteria 1–9 pass, remove the Bearer token **(on the box)**:

```bash
ssh root@$IP "cd /opt/household-os/actual && sed -i '/^MCP_SSE_AUTHORIZATION=/d' mcp.env && docker compose up -d actual-mcp"
```

Re-verify **(workstation):**

**bash:** `probe "Bearer $JWT"` → 200 · `probe ""` → 401

**PowerShell:** `Probe "Bearer $JWT"` → 200 · `Probe ""` → 401

**Rollback (if OIDC misbehaves at any point) — (on the box).** Restore the Bearer
line and remove the OIDC block:

```bash
ssh root@$IP
cd /opt/household-os/actual
echo "MCP_SSE_AUTHORIZATION=<saved-token>" >> mcp.env
sed -i '/^AUTH_PROVIDER=/d' mcp.env        # remove oidc flip
docker compose up -d actual-mcp
exit
```

Then reconfigure client connectors to use the Bearer token header again.

---

## Operations

- **Pin the image.** The compose pins `actual-mcp` to `:v0.7.11` (off `:latest`) so
  an upstream change can't surprise a process holding your financial credentials —
  v0.7.11 is the first semver release with OIDC support on `main` (ADR-0004). Bump
  the tag deliberately after reading release notes and re-run the smoke + auth tests.
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
