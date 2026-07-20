# 0005 — MCP budget server: re-evaluate the OIDC issuer (Cloudflare Access SaaS-OIDC vs Google-direct)

- **Status:** Proposed
- **Date:** 2026-07-20
- **Deciders:** Household OS owner
- **Related:** ADR-0002 (write-capable MCP server); ADR-0003 (Superseded — the failed
  CF-Access-as-issuer attempt, re-examined here); ADR-0004 (Accepted — Google as direct
  issuer; **this ADR revisits that issuer choice** and supersedes it if CF is adopted);
  `docs/mcp-budget-server.md`; `infra/actual/`, `infra/terraform/`
- **Sources:**
  [CF generic OIDC SaaS app](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/saas-apps/generic-oidc-saas/),
  [CF "Secure MCP servers with Access for SaaS"](https://developers.cloudflare.com/cloudflare-one/applications/configure-apps/mcp-servers/saas-mcp/)

## Context

ADR-0004 moved the MCP server to **Google as the direct OIDC issuer**
(`OIDC_ISSUER=https://accounts.google.com`) after declaring Cloudflare Access
"permanently unworkable" as an issuer. Two things since then reopen that choice:

1. **The owner's goal is to stop frequent re-auth prompts** — i.e. *session durability*,
   not longer-lived access tokens. (Longer access tokens would only enlarge the leak
   blast-radius on a write-capable financial endpoint.) The right lever is a short
   access token + a durable, revocable **refresh token**.

2. **The owner asked to re-examine why the Cloudflare attempt actually failed.** It did
   not fail on a fundamental limit — it failed on using the **wrong Cloudflare Access
   application mode**. That changes the comparison materially (next section).

Also reconciled while here: there is **no Auth0** anywhere in the design (a prior
recollection; repo-wide search finds zero references). The deployed MCP image is
**0.8.16**, which already contains the cross-origin JWKS fix
(`OIDC_JWKS_TRUSTED_HOSTS`, upstream #254/#255, shipped v0.8.1) that Google-direct
needs — the flag is simply opt-in and not yet set. The docs/compose still cite the
stale `:v0.7.11`/`:develop` pin; ADR-0004's env block is otherwise current.

## Re-evaluation of the Cloudflare failure (ADR-0003)

ADR-0003's live cutover (issue #14) recorded three blockers. Each is an artifact of
CF Access's **self-hosted application** mode — a reverse-proxy cookie gate that is
*not* an OAuth authorization server — and **does not apply to CF Access's SaaS
application (OIDC) mode**, which is a full OIDC IdP:

| ADR-0003 blocker | Why it happened | In SaaS-OIDC mode |
|---|---|---|
| 1. No `authorization_endpoint` / `token_endpoint` in discovery | Self-hosted apps expose only a `CF_Authorization` cookie + JWKS at `/cdn-cgi/access/certs`; there is no OAuth token endpoint | **Resolved** — a SaaS-OIDC app publishes real `authorization_endpoint` + `token_endpoint`, supports the OAuth 2.1 **PKCE** code flow Claude needs, and issues a JWT `id_token` |
| 2. `bypass` policy vs `cloudflared` JWT minting are mutually exclusive | An attempt to mint the self-hosted app's cookie-JWT non-interactively while also letting non-browser clients through | **Not applicable** — the SaaS-OIDC app *is* the authorization server; there is no `cloudflared`/`bypass` dance. The MCP origin no longer needs a self-hosted Access gate at all (matches ADR-0002's "no Access app on the MCP origin") |
| 3. `AUTH_PROVIDER=oidc` is a hard flip (disables Bearer) | A property of the **agigante80 server**, not of CF | **Issuer-independent** — applies equally to Google. Not a CF-specific blocker |

Cloudflare publishes a dedicated **"Secure MCP servers with Access for SaaS"** guide
for exactly this pattern (OIDC protocol, authorization-code + PKCE, optional refresh
tokens, selectable ID-token scopes, Access policy for the user allowlist). So the CF
path is not only viable — it is a supported, documented pattern. ADR-0003's verdict
should read "self-hosted-app mode was the wrong tool," not "CF cannot be an issuer."

One risk is **shared by CF and Google alike** and is therefore *not* a differentiator:
whether Claude presents the JWT `id_token` (validatable via JWKS) or an opaque
`access_token` (ADR-0004's open question). It is a **gating verification** for whichever
issuer is chosen, not a reason to prefer one.

## Decision

**Recommended: pilot Cloudflare Access SaaS-OIDC as the primary issuer, keeping
Google-direct (ADR-0004) as the already-validated fallback.** Both are gated by the
same JWT-validation check. Concretely:

1. **Stand up a CF Access *SaaS* application (OIDC protocol)** for the MCP server —
   *not* a self-hosted app. Issuer `https://<team>.cloudflareaccess.com`; copy its
   `authorization_endpoint`, `token_endpoint`, JWKS URL, client ID, and client secret
   from the app's config screen. Enable **PKCE**.
2. **Attach a CF Access policy** with the family-email allowlist to that SaaS app, so
   the coarse allowlist stays **in one place** (CF), enforced during login — instead of
   being duplicated into `AUTH_BUDGET_ACL` as Google-direct requires. Keep
   `AUTH_BUDGET_ACL` only for *per-budget* scoping, not as the family gate.
3. **Enable Refresh tokens** on the SaaS app (Advanced settings) and set a **short
   access-token lifetime + longer refresh-token lifetime / app session duration** —
   the direct lever for "stop re-auth prompts," configurable in a way Google's fixed
   1-hour token is not.
4. **Point the MCP server at the CF issuer:** `AUTH_PROVIDER=oidc`,
   `OIDC_ISSUER=https://<team>.cloudflareaccess.com`, `OIDC_ACCEPTED_AUDIENCES=<CF SaaS
   app client ID>`. JWKS is same-origin, so **no `OIDC_JWKS_TRUSTED_HOSTS` needed**.
5. **Keep the reversible cutover principle:** run with `MCP_SSE_AUTHORIZATION` still
   present until the CF path passes the acceptance criteria, then remove it. If the
   shared JWT-vs-opaque check fails on CF and cannot be resolved, **fall back to the
   already-de-risked Google-direct path** (ADR-0004) rather than blocking.

If the owner instead prefers the shortest path to done, **Decision-Alt:** finish
Google-direct (set `OIDC_JWKS_TRUSTED_HOSTS=www.googleapis.com`, publish the Google
OAuth app to "In production" so refresh tokens stop expiring) and treat CF SaaS-OIDC
as a later improvement. Either way this ADR **reaffirms leaving Actual Budget on CF
Access** (ADR-0003 Decision 1 stands).

## Alternatives considered

| Option | "Stop re-auth prompts" fit | Family allowlist | JWKS | Maturity here | Verdict |
|---|---|---|---|---|---|
| **CF Access SaaS-OIDC** (recommended primary) | ✅ configurable access + refresh lifetime + app session duration | ✅ one place — CF Access policy, enforced at login | same-origin (no extra config) | Unproven here — needs one correct-mode pilot | ✅ Best goal-fit, reuses the CF Zero Trust + Google-upstream identity already in the stack, CF-documented for MCP |
| **Google-direct** (ADR-0004, fallback) | ⚠️ fixed 1h access token; relies on refresh + OAuth app in "production" | ❌ duplicated into `AUTH_BUDGET_ACL` | cross-origin — needs `OIDC_JWKS_TRUSTED_HOSTS=www.googleapis.com` | Blockers cleared; 0.8.16 deployed | ✅ Proven fallback; keep as the safety net |
| **Auth0** | ✅ configurable | ❌ a new allowlist home | same-origin | New third-party SaaS dependency | ❌ Dominated by CF for this use case — CF gives the same configurability while reusing existing infra and unifying the allowlist. Only if a concrete CF/Google gap appears |
| **Self-hosted IdP** (Casdoor / Authentik / Keycloak) | ✅ configurable; issues JWT *access* tokens (sidesteps the opaque-token risk) | own | own | New always-on service on the single Hetzner box (ADR-0001 SPOF) | ⚠️ Deferred — the escape hatch if the shared opaque-token risk bites both CF and Google |

## Token-lifetime / session-durability mechanics

- **The goal is durability, not longer access tokens.** Best practice on either issuer:
  **short access token + durable, revocable refresh token.** A long-lived *access*
  token on a write-capable financial endpoint enlarges the leak blast-radius (the exact
  risk ADR-0002/0003 minimize) and is the wrong lever.
- **CF SaaS-OIDC:** access-token lifetime, refresh-token lifetime, and app session
  duration are all configurable; turning on Refresh tokens is a checkbox. This is the
  cleanest way to hit "stop re-auth prompts."
- **Google-direct:** the ID/access token is hard-capped at **1 hour** and cannot be
  lengthened. Seamlessness comes only from refresh tokens, whose durability depends on
  the OAuth app's **publishing status** — "Testing" expires refresh tokens after 7 days
  (the likely source of recurring prompts); "In production" does not. Scopes are only
  `openid email` (non-sensitive), so production publishing needs no Google verification
  review.

## Consequences

**If CF SaaS-OIDC is adopted:**
- **New Terraform:** a `cloudflare_zero_trust_access_application` of `type = "saas"`
  with an OIDC `saas_app` block + a `cloudflare_zero_trust_access_policy` for the
  allowlist. The client secret lands in `mcp.env` on the VPS (design §4.4). Confirm the
  resource schema against the cloudflare provider version in `infra/terraform/versions.tf`.
- **Allowlist unifies** back to CF Access (removes ADR-0004's "two places to keep in
  sync" consequence); `AUTH_BUDGET_ACL` narrows to per-budget scoping only.
- **The MCP origin needs no self-hosted Access gate** — the SaaS app handles auth out of
  band; the CF proxy (WAF/TLS/rate-limiting) is unchanged.
- ADR-0004 becomes **Superseded by ADR-0005** once the pilot passes.

**Shared, regardless of issuer:**
- `AUTH_PROVIDER=oidc` is a **hard flip** — no mixed Bearer/OIDC mode; all clients
  (Claude App, Desktop, Code) complete the OAuth PKCE flow.
- The **JWT-vs-opaque gating check** must pass (Claude must present a token the
  agigante80 server can validate via JWKS). If it fails on both issuers, escalate to a
  self-hosted IdP that issues JWT access tokens, or a token-exchange proxy.
- Reversible via `mcp.env` revert + `docker compose up -d actual-mcp`.

**When to revisit:** if the CF pilot's JWT check fails → fall back to Google-direct; if
both fail → self-hosted IdP; if multi-service SSO consolidation becomes a goal → promote
to a self-hosted IdP for both Actual and MCP.

## Implementation appendix (seeds the build session)

> Design-stage. Confirm upstream env-var names against the pinned image
> (`ghcr.io/agigante80/actual-mcp-server:0.8.16`) `docs/CONFIGURATION.md`, and the CF
> resource schema against the provider in `versions.tf`, before applying.

**CF SaaS-OIDC setup:**
1. Zero Trust → Access → Applications → Add a **SaaS** application → protocol **OIDC**.
   Set the redirect/callback URL(s) for each Claude client; select scopes
   (`openid`, `email`); enable **PKCE**; enable **Refresh tokens**; set access + refresh
   lifetimes / session duration.
2. Add an Access **policy**: Allow, emails in the `family_emails` list (reuse the
   existing variable). Keep Google as the upstream login method (already configured).
3. Copy issuer, endpoints, client ID, client secret into `mcp.env`
   (`AUTH_PROVIDER=oidc`, `OIDC_ISSUER=https://<team>.cloudflareaccess.com`,
   `OIDC_ACCEPTED_AUDIENCES=<client-id>`; **omit** `OIDC_JWKS_TRUSTED_HOSTS`).
4. Configure each Claude connector to the MCP URL; it performs the OAuth PKCE flow
   against the CF endpoints.

**Terraform sketch** (schema-check before use):
```hcl
resource "cloudflare_zero_trust_access_application" "mcp_saas_oidc" {
  account_id = var.cloudflare_account_id
  name       = "Household OS — MCP (SaaS OIDC)"
  type       = "saas"
  saas_app {
    auth_type     = "oidc"
    redirect_uris = var.mcp_oauth_redirect_uris
    scopes        = ["openid", "email"]
    grant_types   = ["authorization_code"]
    # enable PKCE + refresh per provider schema
  }
}
# + cloudflare_zero_trust_access_policy allow-list on family_emails
```

**Acceptance criteria & cutover:** reuse the 9 criteria + runbook in
`docs/mcp-budget-server.md` §7 (do not duplicate). The make-or-break additions:
(a) discovery exposes `authorization_endpoint`/`token_endpoint` and Claude completes
PKCE; (b) the agigante80 server validates the presented token via JWKS (JWT `id_token`,
not opaque); (c) after access-token expiry the client **silently refreshes with no new
login prompt** — the true test of the goal.

**Doc/config reconciliations shipped alongside this ADR:** version pin → `0.8.16`
across compose/docs; `OIDC_JWKS_TRUSTED_HOSTS` documented in the Google block of
`mcp.env.example`; a CF SaaS-OIDC block added there; `infra/terraform/outputs.tf`
`mcp_access_application_aud` help text corrected.
