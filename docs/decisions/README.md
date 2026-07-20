# Decision Log

Architecture Decision Records (ADRs) for Household OS. Each entry captures a
decision that was non-obvious, had real alternatives, and would otherwise get
re-litigated later. Newest decisions get the next number.

Format per record: **Context → Decision → Alternatives considered → Consequences**.
Status is one of `Proposed`, `Accepted`, `Superseded by NNNN`.

| # | Decision | Status | Date |
|---|---|---|---|
| [0001](0001-hosting-provider.md) | Hosting provider: Hetzner Cloud VPS | Accepted | 2026-06-11 |
| [0002](0002-mcp-budget-server.md) | AI budget access via a write-capable MCP server (amends §2.6 read-only finance rule) | Accepted | 2026-06-13 |
| [0003](0003-mcp-oidc-auth.md) | OIDC for the MCP budget server via CF Access — withdrawn; see ADR-0004 | Superseded by 0004 | 2026-06-16 |
| [0004](0004-mcp-google-oidc.md) | MCP budget server: Google as direct OIDC issuer; enables Claude App | Accepted | 2026-06-22 |
| [0005](0005-mcp-auth-issuer-reeval.md) | Re-evaluate MCP auth issuer: CF Access SaaS-OIDC (recommended) vs Google-direct vs Auth0 | Proposed | 2026-07-20 |
