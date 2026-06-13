# 0002 — AI budget access via a write-capable MCP server, amending the read-only finance rule

- **Status:** Accepted
- **Date:** 2026-06-13
- **Deciders:** Household OS owner
- **Related:** design-doc §2.4 (Personal Finance), §2.6 (Integration & Sync Model — the "no two-way sync" hard rule), §4 (Security & Access); ADR-0001 (host); `infra/actual/`, `docs/mcp-budget-server.md`

## Context

We want to interrogate **and manage** the household budget through an AI
assistant — "where did groceries go in May?", but also "recategorize these,
set the dining-out target to $400." Actual Budget has no REST API; all budget
logic lives in the `@actual-app/api` Node library against a local synced copy
(design §2.4). The community has built MCP servers that wrap exactly that
library and expose it to MCP-capable AI clients (Claude.ai/Desktop connectors).

This collides with one of the project's load-bearing rules. Design §2.6 states
a **hard rule: "no two-way sync, ever,"** with finance classified as **Mirror
(read-only)** — Actual is the source of truth and the only edit surface, and the
planned finance worker "never calls `setBudget*` mutators." A write-capable MCP
server is, by definition, a **second write path into Actual**. Adopting it is
therefore not a neutral add-on; it requires a conscious amendment to §2.6.

A second tension is access (design §4.1): the entire human-access model is
**Cloudflare Access (Google SSO + family allowlist)**. Access only admits
interactive browser logins, so it **cannot front an MCP endpoint** — an MCP
client is a non-browser client and would receive the login page, the same
failure native Actual apps hit (install-actual.md §10f).

## Decision

1. **Adopt [`agigante80/actual-mcp-server`](https://github.com/agigante80/actual-mcp-server)**
   as a sibling container on the existing VPS (ADR-0001), connecting to Actual
   over the internal Docker network (`http://actual-server:5006`), reusing the
   same `@actual-app/api` plumbing the finance worker will later use. Chosen as
   the **most capable** option: 71 tools (~84% API coverage), HTTP/Docker-native,
   and Bearer **plus** OIDC/JWT auth — purpose-built for a remote write server.

2. **Amend design §2.6 finance row to a *scoped* exception.** Finance gains a
   **single, narrow two-way write path: the MCP server.** Everything else holds —
   the dashboard mirror and overspend worker remain strictly read-only, and
   Actual's UI remains the primary edit surface. The MCP server is an *interactive,
   human-driven* writer, not an automated sync; there is still no background
   reconciliation loop, which is the complexity §2.6 exists to forbid.

3. **Gate it with the MCP server's own auth, not Cloudflare Access.** Serve it at
   a dedicated, Cloudflare-proxied subdomain (`mcp-budget.<domain>`) with **no
   Access application**. A static **Bearer token** is the v1 gate (256-bit,
   `openssl rand -hex 32`), with **OIDC/JWT** documented as the hardening upgrade.
   Secrets stay on the VPS (design §4.4), never on family laptops.

## Alternatives considered

| Option | Verdict |
|---|---|
| **agigante80/actual-mcp-server** (chosen) | ✅ Most capable: 71 tools, native HTTP/Docker, Bearer+OIDC+per-user ACL, connection pooling. ⚠️ ~19★ single-maintainer holding financial creds; no tool-level read-only mode. |
| s-stefanov/actual-mcp | ~160★ (more community vetting), read-only by default, write behind `--enable-write`. Rejected as **less capable** and HTTP/auth are bolted-on; revisit if the maintainer-trust gap on the chosen project becomes a concern. |
| Keep finance strictly read-only (status quo) | Rejected: forecloses the "manage" use case the owner explicitly wants. The read-only half is still available by simply not deploying this. |
| stdio MCP on each family laptop (Claude Desktop) | Rejected: puts the Actual server password, E2E key, and a full budget copy on every device — violates the §4.4 "secrets on the VPS" model. |
| Front the MCP host with Cloudflare Access | Rejected: Access blocks non-browser MCP clients (install §10f). A service-token bypass is noted as optional defense-in-depth, not the primary gate. |

## Consequences

**Accepted trade-offs:**

- **§2.6 is no longer absolute for finance.** There is now one sanctioned
  write path. This is the decision most likely to be re-litigated, hence the ADR.
- **A write-capable financial endpoint is internet-reachable**, gated by a
  shared Bearer token rather than Google SSO. Mitigations: Cloudflare proxy
  (hides origin IP, TLS, WAF, rate-limiting), a 256-bit token, container/network
  isolation (the MCP container's only egress need is `actual-server`), and OIDC
  as the upgrade path. The full threat model lives in `docs/mcp-budget-server.md`.
- **Third-party code holds high-value secrets** (Actual password, and the E2E
  key if encryption is on). Mitigation: pin a reviewed image tag rather than
  tracking `latest` blindly; run least-privilege.
- **No tool-level read-only mode** on the chosen project — all 71 tools are live,
  so the AI *can* mutate. The owner accepts this as the cost of the "manage"
  capability; **network isolation + the token are the only guardrails**, and an
  errant write is recoverable via Actual's own undo and the §5.1 backups.

**When this should be revisited:** if the single-maintainer supply-chain risk
proves uncomfortable (fall back to s-stefanov read-only), if a role/visibility
need appears (design §4.2 — switch the Bearer token for OIDC + per-user ACLs),
or if a tool-level read-only mode becomes desirable (deploy a second, read-only
instance for the dashboard/alerts path).
