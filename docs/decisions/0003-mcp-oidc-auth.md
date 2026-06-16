# 0003 — OIDC for the MCP budget server; leave Actual on Cloudflare Access

- **Status:** Proposed
- **Date:** 2026-06-16
- **Deciders:** Household OS owner
- **Related:** ADR-0002 (write-capable MCP server — this is the "hardening upgrade"
  it names); design-doc §4.1 (Cloudflare Access human-access model), §4.2
  (roles/visibility), §4.4 (secrets on the VPS); `docs/mcp-budget-server.md`
  ("Hardening upgrade — OIDC instead of a shared Bearer token"); `infra/actual/`,
  `infra/terraform/`

## Context

ADR-0002 deployed `agigante80/actual-mcp-server` gated by a **static 256-bit
Bearer token** (`MCP_SSE_AUTHORIZATION`, `openssl rand -hex 32`), and explicitly
flagged OIDC/JWT as the planned hardening step *"if a role/visibility need
appears … switch the Bearer token for OIDC + per-user ACLs."* This ADR decides
whether and how to take that step. The question that prompted it: *would moving
Actual and the MCP server to OIDC increase security, and does it conflict with /
duplicate the existing Google SSO?*

Two clarifications drive the whole decision, and they are easy to get wrong:

1. **"OIDC" is not an alternative to "Google SSO" — Google SSO *is* OIDC.** The
   existing "Google SSO" is **Cloudflare Access acting as an OIDC/OAuth relying
   party to Google**, with a family-email allowlist (design §4.1, ADR-0002,
   `infra/terraform/main.tf`). So the real question is never "OIDC vs Google" —
   it is *which issuer mints the JWT that the MCP server validates*, and *which
   layer enforces identity*.

2. **The two services are not symmetric.** They need different answers:
   - **Actual Budget is a browser app.** It is already behind Cloudflare Access →
     Google SSO + allowlist + 1-month sessions. That is *already* federated OIDC
     identity. Moving Actual to its own native OpenID would **relocate** the SSO
     boundary (proxy → app), not add one — and stacking both yields a redundant
     double login.
   - **The MCP server is a non-browser service.** Cloudflare Access cannot front
     it (Access only admits interactive browser logins — install §10f, ADR-0002),
     so it is gated by a *shared, anonymous, non-expiring* secret. This is the one
     place where OIDC is a genuine security upgrade, not lateral motion.

### Why the shared Bearer token is the weak point

The MCP host is an **internet-reachable, write-capable financial endpoint** with
**no tool-level read-only mode** — all 71 tools are live (ADR-0002 consequences).
The single shared token has three structural weaknesses:

| Property | Shared Bearer token (today) | OIDC/JWT |
|---|---|---|
| Identity | Anonymous — every family member is one principal; no audit trail | Per-user `sub`; you know *who* called what |
| Revocation | All-or-nothing; rotating re-keys everyone | Revoke one user at the IdP |
| Expiry | Static until manual rotation | Short-lived access tokens, auto-refreshed |
| Authorization | None — token = all 71 write tools on all budgets | `AUTH_BUDGET_ACL` scopes user → budget |
| Blast radius if leaked | Full write access to finances, indefinitely | Bounded by token lifetime × that user's ACL |

The bottom row is the point: a leaked Bearer token is unbounded write access to
the household finances until noticed and rotated. OIDC shrinks both the **window**
(short expiry) and the **scope** (per-user ACL), and adds the audit trail design
§4.2 wants.

### The honest blocker

Full OIDC needs an **issuer that is online at auth time** — which the project does
not run today. So this decision is really *"which issuer do we adopt without
standing up a new always-on service?"* That constraint, plus clarification (1)
above, points squarely at reusing the Cloudflare/Google identity already in place.

## Decision

1. **Leave Actual Budget on Cloudflare Access (Google SSO).** Do **not** migrate
   Actual to its native OpenID. Access already gives it federated identity, the
   family allowlist, and session expiry; native OpenID would relocate that
   boundary for no security gain and risk a redundant double-login if stacked.
   Revisit only if/when we want to retire the Access layer wholesale.

2. **Migrate the MCP server from the shared Bearer token to OIDC/JWT**, using
   **Cloudflare Access as the OIDC issuer** so we **reuse the existing Google SSO
   and family allowlist** — no new always-on identity provider. The MCP server
   validates a Cloudflare-issued JWT (issuer + audience + signature); per-user
   scoping via `AUTH_BUDGET_ACL`. Google SSO becomes *more* central, not
   redundant.

3. **Phase it as a credentialed, reversible cutover.** Keep the Bearer token
   working until OIDC is validated end-to-end behind it (defense-in-depth during
   transition), then remove `MCP_SSE_AUTHORIZATION`. Treat "the agigante80 server
   genuinely validates the JWT (not cosmetically)" as a **gating verification
   step**, given it is ~19★ single-maintainer code holding the Actual password
   (ADR-0002 supply-chain note).

## Alternatives considered

### Which issuer mints the MCP server's JWT

| Option | Verdict |
|---|---|
| **Cloudflare Access as OIDC issuer** (chosen) | ✅ Reuses Google SSO + family allowlist already in Terraform; **no new always-on service**; one identity surface to manage. ⚠️ MCP client must obtain a Cloudflare-issued JWT and attach it; validate that the MCP server accepts CF's issuer/JWKS. |
| **Google as the direct OIDC issuer** (`OIDC_ISSUER=https://accounts.google.com`) | Reuses Google identities, but **loses the Cloudflare allowlist enforcement** — the family gate moves entirely into `AUTH_BUDGET_ACL`, which is easy to under-configure. No proxy-side WAF on the auth. Rejected as weaker for the same effort. |
| **Self-hosted IdP** (Authelia / Authentik / Keycloak / Pomerium) | Max control + native per-user ACL + would consolidate auth across future Phase-2 services (Hub, Home Assistant bridge). ❌ A whole new always-on service to run/patch/back up on the single Hetzner box (ADR-0001 single-box SPOF). Overkill for a household *today*; **the right answer later** if multi-service SSO consolidation becomes a goal. |
| **Cloudflare Access service token** (`CF-Access-Client-Id`/`Secret` headers) in front | Not true per-user OIDC — a *second shared secret* — but a fast defense-in-depth layer that puts the MCP host behind Cloudflare Access without breaking non-browser clients (already noted optional in `mcp-budget-server.md`). Adopt as an **interim/extra layer**, not the end state. |
| **Keep the shared Bearer token** (status quo) | Rejected for the reasons in Context — anonymous, non-expiring, unbounded blast radius on a write-capable financial endpoint. Acceptable only as the *fallback* if OIDC validation in the chosen server proves untrustworthy. |

### Actual Budget auth

| Option | Verdict |
|---|---|
| **Keep Cloudflare Access (Google SSO)** (chosen) | ✅ Already federated OIDC; allowlist; 1-month sessions; zero work. |
| **Actual native OpenID, drop Access** | Lateral move — relocates the boundary, no added layer; would need Actual's `ACTUAL_OPENID_*` config and re-validation of the COOP/COEP + reverse-proxy path. Only worth it to retire Access entirely. Deferred. |
| **Stack both (Access + Actual OpenID)** | ❌ Redundant double login against the same Google identity. Rejected. |

## Consequences

**Accepted trade-offs:**

- **A new runtime dependency on the issuer.** OIDC auth now depends on Cloudflare
  Access being reachable at auth time. A misconfigured OIDC setup (wrong `aud`,
  unvalidated issuer, clock skew, stale JWKS) can be *less* safe than a correctly
  handled random secret — so the security win is **conditional on careful
  validation**, captured as explicit acceptance criteria below.
- **Client-side complexity.** The MCP client (Claude.ai / Desktop connector) must
  obtain and attach a JWT instead of a static header. If a given client cannot do
  the OIDC flow, the Cloudflare service-token layer (headers) is the fallback gate
  for that client.
- **Trust in third-party token validation.** We are relying on agigante80's OIDC
  code to validate signatures/issuer/audience correctly. Mitigation: pin a
  reviewed image tag (ADR-0002 already calls for pinning off `:latest`), and run
  the negative tests in the acceptance criteria before removing the Bearer token.
- **Actual and MCP now authenticate via two different mechanisms** (Access cookie
  vs JWT/header) against the **same** Google identity. This is intentional — the
  browser vs non-browser split — but means two configs to keep allowlists in sync.

**When this should be revisited:**
- If Phase-2 services multiply, **promote to a self-hosted IdP** (Authentik /
  Keycloak) to consolidate SSO across everything — at which point both Actual and
  the MCP server point at it, and this ADR is partially superseded.
- If agigante80's OIDC validation proves untrustworthy, **fall back** to the
  shared Bearer token + Cloudflare service-token layer (still an improvement over
  status quo via the second factor) until a read-only s-stefanov split or IdP move.

---

## Implementation appendix (for the build session)

> This is design-stage. Nothing below is applied yet. Confirm current upstream
> env-var names against the agigante80/actual-mcp-server release you pin —
> the names here come from `docs/mcp-budget-server.md` and may have changed.

### Pre-work / unknowns to resolve first

1. **Pin and read the upstream release.** Choose a specific tag (not `:latest`),
   read its auth docs/source, and confirm the exact OIDC env-var names and that it
   **validates issuer + audience + signature** (JWKS fetched from the issuer), not
   just "a bearer string is present."
2. **Confirm Cloudflare Access can issue an OIDC token the MCP client can use.**
   Decide the concrete flow: (a) Cloudflare Access *as IdP/OIDC provider* issuing
   JWTs the server validates against CF's issuer + JWKS, vs (b) the simpler
   **service-token** header layer. If (a) is not cleanly supported by the client,
   ship (b) first and treat true per-user OIDC as a follow-up.
3. **Confirm whether the MCP client (Claude.ai / Desktop connector) can perform an
   OIDC flow or only attach static headers.** This determines (a) vs (b).

### Target config — `infra/actual/mcp.env` (OIDC path)

```
AUTH_PROVIDER=oidc
OIDC_ISSUER=https://<your-team>.cloudflareaccess.com      # or chosen issuer
OIDC_RESOURCE=<expected-jwt-aud>                          # audience the server enforces
AUTH_BUDGET_ACL=<user-email-or-sub → budget-syncid map>  # per-user scoping
# Keep MCP_SSE_AUTHORIZATION set during transition; REMOVE only after OIDC verified
# ACTUAL_PASSWORD / ACTUAL_BUDGET_SYNC_ID / ACTUAL_BUDGET_PASSWORD unchanged
```

Also update `infra/actual/mcp.env.example` with the OIDC block (commented) and a
note that Bearer and OIDC are mutually exclusive end-states.

### Interim defense-in-depth — Cloudflare Access service token

If shipping the header layer first:
- Create a service token in Cloudflare Zero Trust; the client attaches
  `CF-Access-Client-Id` / `CF-Access-Client-Secret`.
- This *does* require an Access application on `mcp-budget.<domain>` configured to
  accept the **service token** (so it does not bounce non-browser clients to the
  Google login page — the failure mode in `mcp-budget-server.md` troubleshooting).
- Terraform: this reverses ADR-0002's "no Access app on the MCP host" specifically
  for the service-token case — capture that nuance in `infra/terraform/` comments
  so it is not mistaken for the misconfiguration the troubleshooting table warns
  about.

### Terraform / infra touch points

- `infra/terraform/` — if using Cloudflare as issuer or a service token, add the
  relevant Zero Trust resources (service token, and/or Access app scoped to the
  MCP host) and outputs. Keep the budget host's existing Access app unchanged.
- `infra/actual/docker-compose.yml` — pin the `actual-mcp` image tag; no structural
  change otherwise (auth is env-driven).
- No change to `actual-server` or its Caddy site — Actual stays on Cloudflare
  Access per Decision (1).

### Acceptance criteria (must all pass before removing the Bearer token)

1. **Positive:** a request bearing a valid JWT from the configured issuer/audience
   succeeds on a read tool ("list accounts").
2. **Negative — no token:** rejected (401).
3. **Negative — wrong issuer:** a well-formed JWT from a *different* issuer is
   rejected.
4. **Negative — wrong audience:** a valid-issuer JWT with the wrong `aud` is
   rejected.
5. **Negative — expired:** an expired token is rejected (proves expiry is checked).
6. **Negative — tampered signature:** a token with a broken signature is rejected
   (proves signature validation is real, not cosmetic — the key supply-chain test).
7. **ACL:** a user mapped to budget A cannot reach budget B (if `AUTH_BUDGET_ACL`
   is configured for >1 budget).
8. **Write path still works** for an authorized user (one $1 test transaction,
   confirmed in Actual, then deleted — same smoke test as ADR-0002 deploy runbook).
9. **Rollback verified:** re-enabling the Bearer token path restores access (proves
   the cutover is reversible) before you commit to removing it.

### Cutover sequence

1. Pin image tag; deploy with **both** Bearer and OIDC env present.
2. Run acceptance criteria 1–9 with OIDC.
3. Remove `MCP_SSE_AUTHORIZATION`; `docker compose up -d actual-mcp`; re-run 1–2.
4. Update `docs/mcp-budget-server.md` (promote the OIDC section from "upgrade" to
   "current"; move Bearer to "legacy/fallback") and flip this ADR to **Accepted**.

### Docs to update on completion

- `docs/mcp-budget-server.md` — security model + deploy runbook reflect OIDC as the
  live gate.
- `docs/decisions/0003-mcp-oidc-auth.md` — Status → Accepted, date the cutover.
- `docs/decisions/README.md` — already indexed by this change.
