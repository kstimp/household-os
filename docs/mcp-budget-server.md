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
2. **The MCP server's own auth gate.** Either **per-user OIDC/JWT** (ADR-0003
   target — `AUTH_PROVIDER=oidc`, JWKS-validated, per-user `AUTH_BUDGET_ACL`) or
   the **legacy shared Bearer token** (`MCP_SSE_AUTHORIZATION`, 256-bit,
   `openssl rand -hex 32`; clients send `Authorization: Bearer <token>`). See
   "Auth" below — OIDC is the current target, Bearer the fallback.
3. **(Optional) Cloudflare Access service token.** A non-interactive header gate
   at the edge (`CF-Access-Client-Id` / `CF-Access-Client-Secret`) in front of (2),
   added by `var.enable_mcp_access_service_token` (ADR-0003). Off by default.
4. **Network isolation.** The container is not published to the host (no `ports:`);
   only Caddy reaches it, and its only outbound need is `actual-server`.
5. **Secrets stay on the VPS** (`mcp.env`, gitignored), never on family laptops —
   consistent with design §4.4.

**Residual risks (accepted in ADR-0002, narrowed by ADR-0003):** a write-capable
financial endpoint is internet-reachable; under the legacy Bearer token it sits
behind a *shared, non-expiring* secret rather than per-person SSO (OIDC shrinks
both the window and the scope); and third-party code holds the Actual password
(and the E2E key if encryption is on).

### Auth: per-user OIDC (current target) — ADR-0003

Per ADR-0003 the gate moves from the shared Bearer token to **per-user OIDC/JWT**,
using **Cloudflare Access as the issuer** so the existing Google SSO + family
allowlist are reused (no new always-on identity provider). The server validates the
token's **signature + issuer + audience** against the issuer's JWKS — per-user `sub`,
short expiry, an audit trail, and per-budget ACLs replace the anonymous shared token.

Set in `mcp.env` (var names confirmed against agigante80/actual-mcp-server **v0.7.9**,
`docs/guides/AI_CLIENT_SETUP.md` — they drifted from earlier drafts, note `OIDC_SCOPES`):

```
AUTH_PROVIDER=oidc
OIDC_ISSUER=https://<your-team>.cloudflareaccess.com    # issuer; JWKS at <issuer>/cdn-cgi/access/certs
OIDC_RESOURCE=<expected-jwt-aud>                         # must equal the JWT `aud` (CF Access AUD tag)
OIDC_SCOPES=                                             # leave EMPTY for issuers with no `scope` claim (CF Access, Casdoor)
AUTH_BUDGET_ACL={"you@gmail.com":["<budget-sync-id>"]}  # principal(email|sub|group:<name>) → [budget sync ids]; ["*"]=all
# keep MCP_SSE_AUTHORIZATION set during the cutover; remove it only after OIDC verifies
```

**Interim / extra layer — Cloudflare Access service token.** If a given MCP client
can't complete the OIDC flow but *can* attach custom headers, put the host behind a
non-interactive Access **service token** as a defense-in-depth gate: set
`enable_mcp_access_service_token = true` in Terraform, then have the client send
`CF-Access-Client-Id` / `CF-Access-Client-Secret`. This is a deliberate, narrow
reversal of ADR-0002's "no Access app on the MCP host" — and is **not** the
misconfiguration the troubleshooting table warns about, because the Access policy is
`non_identity` (service token only) and never redirects to a Google login page. See
the Terraform comments and `var.enable_mcp_access_service_token`.

> **Why this matters (supply-chain).** The OIDC validation is third-party,
> ~19★ single-maintainer code holding the Actual password. Before removing the
> Bearer token, run the OIDC acceptance criteria below — especially the
> tampered-signature and wrong-issuer/audience negatives — to confirm validation
> is real, not cosmetic. ADR-0003 gates the cutover on exactly these tests.

### OIDC cutover — acceptance criteria & sequence (ADR-0003)

This is the *what*; the executable step-by-step (commands, probes, rollback) is the
**[OIDC cutover deployment runbook](#7-oidc-cutover--deployment-runbook-adr-0003)**
(Deploy runbook §7). Run on the box with **both** Bearer and OIDC env present (defense
in depth during transition). All must pass **before** removing `MCP_SSE_AUTHORIZATION`:

1. **Positive:** a valid JWT (correct issuer + audience) succeeds on a read tool
   ("list accounts").
2. **No token → 401.**
3. **Wrong issuer → rejected** (well-formed JWT from a different issuer).
4. **Wrong audience → rejected** (valid issuer, wrong `aud`).
5. **Expired → rejected** (proves expiry is checked).
6. **Tampered signature → rejected** (proves signature validation is real — the key
   supply-chain test).
7. **ACL:** a user mapped to budget A cannot reach budget B (if `AUTH_BUDGET_ACL`
   covers >1 budget).
8. **Write path works** for an authorized user (add a $1 test txn, confirm in Actual,
   delete — same smoke test as the deploy runbook).
9. **Rollback verified:** re-enabling the Bearer path restores access (cutover is
   reversible) before you commit to removing it.

Then cut over: remove `MCP_SSE_AUTHORIZATION` → `docker compose up -d actual-mcp` →
re-verify (1) positive and (2) no-token.

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

Add a **custom connector** in Claude.ai / Claude Desktop pointing at:

- **URL:** `https://<mcp_host>/http`  (the `MCP_HTTP_PATH` default is `/http`)
- **Auth (legacy Bearer):** `Authorization: Bearer <the token from mcp.env>`
- **Auth (OIDC target):** attach a JWT from the configured issuer (its `aud` must
  match `OIDC_RESOURCE`) — see the "Auth: per-user OIDC" section and run the OIDC
  acceptance criteria before retiring the Bearer token.
- **(Optional) service-token headers:** if `enable_mcp_access_service_token` is on,
  also send `CF-Access-Client-Id` / `CF-Access-Client-Secret` (from the
  `mcp_access_service_token_*` Terraform outputs).

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

### 7. OIDC cutover — deployment runbook (ADR-0003)

Migrate the gate from the shared Bearer token to per-user OIDC. Run this **after**
the Bearer deployment (steps 1–6) is live; it keeps Bearer working until OIDC is
verified, so it is reversible at every step. Commands run in an SSH session on the
box unless noted. `$IP` / `$MCP_HOST` come from `terraform output` (step 2).

**7a. (optional) Stand up the Cloudflare Access service-token layer.** Skip if you
are doing pure OIDC (path a). From `infra/terraform/` on your workstation:

```bash
# Enable the opt-in layer, then apply (adds 1 Access app + 1 service token on the MCP host):
echo 'enable_mcp_access_service_token = true' >> terraform.tfvars
terraform apply
terraform output -raw mcp_access_service_token_client_id      # CF-Access-Client-Id
terraform output -raw mcp_access_service_token_secret         # CF-Access-Client-Secret (store with the client)
```

**7b. Add the OIDC block to `mcp.env` (keep the Bearer token set).**

```bash
ssh root@$IP
cd /opt/household-os/actual
cat >> mcp.env <<'OIDC'
AUTH_PROVIDER=oidc
OIDC_ISSUER=https://<your-team>.cloudflareaccess.com
OIDC_RESOURCE=<expected-jwt-aud>
OIDC_SCOPES=
AUTH_BUDGET_ACL={"you@gmail.com":["<budget-sync-id>"]}
OIDC
nano mcp.env          # fill the three <...> placeholders; leave MCP_SSE_AUTHORIZATION in place
docker compose up -d actual-mcp
docker compose logs --tail=40 actual-mcp   # should report OIDC/JWKS init, no errors
```

**7c. Obtain a valid JWT for testing** (path a). On your workstation, using
`cloudflared` against the MCP host's Access app (its AUD must equal `OIDC_RESOURCE`):

```bash
cloudflared access login  https://$MCP_HOST
JWT=$(cloudflared access token --app=https://$MCP_HOST)   # short-lived, issuer-minted
```

**7d. Run the acceptance criteria.** This probe POSTs a standard MCP `tools/list`
(gated by the auth layer, so HTTP status cleanly proves accept/reject) and prints the
status code:

```bash
probe() {  # usage: probe "<Authorization header value>" [extra curl args...]
  curl -s -o /dev/null -w '%{http_code}\n' \
    -X POST "https://$MCP_HOST/http" \
    -H 'Content-Type: application/json' \
    ${1:+-H "Authorization: $1"} "${@:2}" \
    --data '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
}

# 1. Positive — valid JWT succeeds (expect 200); then confirm a real read in your AI client:
probe "Bearer $JWT"
# 2. No token        → expect 401:
probe ""
# 3. Wrong issuer    → expect 401/403 (a well-formed JWT minted by a different issuer):
probe "Bearer $WRONG_ISSUER_JWT"
# 4. Wrong audience  → expect 401/403 (a cloudflared token for a DIFFERENT Access app):
probe "Bearer $WRONG_AUD_JWT"
# 5. Expired         → expect 401/403 (reuse $JWT after its exp; CF tokens are short-lived):
probe "Bearer $EXPIRED_JWT"
# 6. Tampered sig    → expect 401/403 (flip the last char of the signature segment):
probe "Bearer $(printf '%s' "$JWT" | sed 's/.$/X/')"
# 7. ACL (only if AUTH_BUDGET_ACL covers >1 budget): from the AI client, a user mapped
#    to budget A must NOT be able to read budget B.
```

> Tokens for tests 3–5 come from the issuer side: #3 sign any JWT with a non-CF key
> (e.g. `https://accounts.google.com`), #4 a `cloudflared access token` for a second
> Access app, #5 a captured `$JWT` reused past its expiry. All must be **rejected** —
> especially #6: a tampered signature that is *accepted* means validation is cosmetic;
> do **not** remove the Bearer token in that case (fall back per ADR-0003).

**7e. Write-path + rollback checks.**

```bash
# 8. Write path: from the AI client (now on the JWT), add a $1 test txn, confirm it
#    in the Actual web app, then delete it — same smoke test as step 6.
# 9. Rollback: temporarily present the Bearer token instead of the JWT and confirm it
#    still works while AUTH_PROVIDER=oidc is being validated:
probe "Bearer $(grep '^MCP_SSE_AUTHORIZATION=' mcp.env | cut -d= -f2)"
```

**7f. Cut over (remove the Bearer token) once 1–9 pass.**

```bash
sed -i '/^MCP_SSE_AUTHORIZATION=/d' mcp.env       # remove the legacy shared secret
docker compose up -d actual-mcp
probe "Bearer $JWT"   # re-verify positive → 200
probe ""              # re-verify no-token → 401
```

Then update the connector to the JWT (and, if 7a is on, the `CF-Access-Client-Id` /
`CF-Access-Client-Secret` headers), and flip **ADR-0003** Status → Accepted with
today's date in `docs/decisions/0003-mcp-oidc-auth.md` and `docs/decisions/README.md`.

**Rollback (if OIDC misbehaves at any point):** restore the Bearer line in `mcp.env`
(`echo "MCP_SSE_AUTHORIZATION=<saved token>" >> mcp.env`), remove or comment the
`AUTH_PROVIDER=oidc` line, `docker compose up -d actual-mcp`, and point the connector
back at the Bearer header. If you enabled 7a and want it gone too, set
`enable_mcp_access_service_token = false` and `terraform apply`.

---

## Operations

- **Pin the image.** The compose pins `actual-mcp` to `:v0.7.9` (off `:latest`) so
  an upstream change can't surprise a process holding your financial credentials —
  this is also the tag whose `docs/guides/AI_CLIENT_SETUP.md` defines the OIDC env
  vars above. Bump the tag deliberately and re-run the smoke + auth tests after.
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
