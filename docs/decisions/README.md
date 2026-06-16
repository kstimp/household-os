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
| [0003](0003-mcp-oidc-auth.md) | OIDC for the MCP budget server; leave Actual on Cloudflare Access | Proposed | 2026-06-16 |
