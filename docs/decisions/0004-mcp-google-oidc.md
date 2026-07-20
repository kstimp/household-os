# 0004 — MCP budget server: Google as direct OIDC issuer; Claude App enabled

- **Status:** Accepted — issuer choice under re-evaluation by ADR-0005
- **Date:** 2026-06-22
- **Deciders:** Household OS owner
- **Related:** ADR-0002 (write-capable MCP server); ADR-0003 (Superseded — OIDC via
  Cloudflare Access; see that ADR for failure details); ADR-0005 (re-evaluates the
  issuer choice — CF Access *SaaS-OIDC* found viable after all); `docs/mcp-budget-server.md`;
  `infra/actual/`

> **Update (2026-07-20, ADR-0005):** the image pin cited below (`:v0.7.11`) is stale —
> the deployed version is **`:0.8.16`**, and Google-direct additionally requires
> **`OIDC_JWKS_TRUSTED_HOSTS=www.googleapis.com`** (cross-origin JWKS fix, upstream
> #254/#255, shipped v0.8.1). ADR-0005 also revisits the core claim below that CF Access
> is "permanently unworkable": that was true of CF's *self-hosted app* mode, but its
> *SaaS-OIDC* mode is a full OIDC IdP and is the recommended path. This ADR's
> Google-direct decision remains valid as the proven fallback.

## Context

ADR-0003 proposed migrating the MCP server from a shared Bearer token to per-user
OIDC/JWT using Cloudflare Access as the OIDC issuer. Live implementation (issue #14,
2026-06-21) revealed three independent blockers that make CF Access permanently unworkable
as the issuer (full details in ADR-0003):

1. **CF Access OIDC discovery is browser-only.** The discovery document does not publish
   `authorization_endpoint` or `token_endpoint`. Claude connectors need OAuth 2.1 PKCE to
   obtain tokens; CF Access cannot supply them.
2. **Bypass policy and `cloudflared` JWT minting are mutually exclusive.** The MCP host
   needs a `bypass` CF Access policy so non-browser clients pass through. With `bypass`
   active, `cloudflared` cannot mint JWTs. Both requirements cannot coexist.
3. **`AUTH_PROVIDER=oidc` is a hard flip, not additive.** Enabling OIDC completely
   disables Bearer token auth server-wide.

Additionally, the claude.ai Integrations UI does **not** support static Bearer token
configuration for custom connectors — only OAuth client credentials. Without OAuth, the
Claude App (mobile/web) cannot be used at all, which is the primary use case driving this
migration.

**Google (`https://accounts.google.com`) resolves all three blockers:**
- Publishes a standard OIDC discovery document including `authorization_endpoint` and
  `token_endpoint` — Claude connectors can complete OAuth 2.1 PKCE.
- Is a direct issuer; no CF Access bypass-policy conflict applies.
- Does not interact with the Bearer-vs-OIDC hard flip — Google *is* the auth mechanism.

The household already uses Google identities via CF Zero Trust. The family Google accounts
remain the authoritative identity; the allowlist moves from CF Access (network layer) into
`AUTH_BUDGET_ACL` (application layer). The CF proxy (WAF, TLS, rate-limiting) is
unchanged.

## Decision

1. **Migrate the MCP server to Google OAuth 2.0 / OIDC** (`OIDC_ISSUER=https://accounts.google.com`).

2. **Create a Google Cloud Console OAuth 2.0 Web Application client.** The client ID
   becomes the `aud` claim the MCP server validates against.

3. **Configure `AUTH_BUDGET_ACL`** with the family's Gmail addresses, replicating the CF
   Access allowlist at the application layer (same identities, different enforcement point).

4. **Pin the image to `:v0.7.11`.** OIDC support landed in v0.7.11 on `main` (released
   2026-06-20). The `:develop` tag used as a workaround in the prior attempt is no longer
   needed. Bump deliberately after reading release notes; re-run smoke + auth tests.

5. **All three clients (Claude App, Claude Desktop, Claude Code) use OAuth.** Because
   `AUTH_PROVIDER=oidc` is a hard flip that disables Bearer server-wide, there is no mixed
   mode — all clients must complete the Google OAuth flow.

## Alternatives considered

| Option | Verdict |
|---|---|
| **Google direct OIDC** (chosen) | ✅ Resolves all three ADR-0003 blockers. Enables Claude App. Reuses same Google identities already in CF Zero Trust. |
| CF Access as OIDC issuer | ❌ Permanently blocked by three independent issues (ADR-0003). |
| Bearer token permanent | Static token works for Claude Desktop (config file) and Claude Code (CLI flag) only. Claude.ai UI requires OAuth — mobile use case blocked. |
| Self-hosted IdP (Authentik, Keycloak) | ADR-0003 explicitly rejected: overkill for single-box household. Right answer if multi-service SSO consolidation becomes a goal. |
| CF Access service token | Second shared secret. Doesn't enable Claude App OAuth flow. Doubles operational surface without improving per-user identity. |

## Consequences

**Accepted trade-offs:**

- **New Google Cloud Console dependency.** A Google OAuth 2.0 Web Application client must
  be created and maintained. The client secret is stored on the VPS (`mcp.env`) and
  referenced in each AI client's connector configuration.

- **Family allowlist moves to `AUTH_BUDGET_ACL`.** When adding a family member, update
  *both* the CF Access identity allowlist (for Actual Budget web access) and
  `AUTH_BUDGET_ACL` in `mcp.env` (for MCP budget access). Two places to keep in sync.

- **ID token vs. access token (open question — gated by acceptance criterion 1).**
  Google OAuth returns an opaque `access_token` and a JWT `id_token`. The agigante80
  server validates JWTs via JWKS — opaque access tokens cannot be validated this way. If
  Claude sends the `access_token` (not `id_token`) as Bearer, criterion 1 will fail with a
  JWT parse error in the server logs. If that happens, fallback options are: (a) investigate
  whether Claude's OIDC-aware flow sends the `id_token` instead, (b) use a Cloudflare
  Worker as a lightweight token exchange proxy, or (c) switch to Casdoor/Authentik which
  issue JWT access tokens natively.

- **CF proxy unchanged.** Cloudflare WAF, TLS, and rate-limiting remain in front of the
  MCP server. The security model is: CF proxy → Google JWT validated at the MCP server.

- **All clients on OAuth after the hard flip.** There is no Bearer fallback once
  `AUTH_PROVIDER=oidc` is set. Roll back by reverting `mcp.env` and restarting
  `actual-mcp` (see deployment runbook rollback step).

**When to revisit:**

- If acceptance criterion 1 fails (opaque access token) → investigate token exchange or
  switch to an IdP that issues JWT access tokens (Casdoor, Authentik).
- If a household member needs a scoped budget view → extend `AUTH_BUDGET_ACL` with their
  email and specific sync IDs.
- If multi-service SSO consolidation becomes a goal → promote to a self-hosted IdP
  (Authentik/Keycloak) at which point both Actual and the MCP server point at it and this
  ADR is partially superseded.
