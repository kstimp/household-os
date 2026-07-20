---
name: Bug report
about: Something in the infra, an app, or a runbook isn't working as documented
title: "[bug]: "
labels: bug
---

## What's wrong

<!-- Clear description of the problem. What did you expect vs. what happened? -->

## Area

<!-- Which part? e.g. Terraform, Actual/Caddy stack, MCP budget server, college app, a specific runbook. -->

## Steps to reproduce

1.
2.
3.

## Relevant logs / output

<!--
Paste errors, `docker compose logs`, terraform output, etc.
⚠️ REDACT SECRETS: tokens, passwords, API keys, IP addresses you don't want public,
the Actual server/encryption passwords, R2 keys, device tokens.
-->

```
```

## Environment

- Where it's running: <!-- local laptop / Hetzner VPS / other -->
- Component version / image tag (if known): <!-- e.g. actual-server:25.x, actual-mcp-server v0.8.1 -->
- Local OS + shell (if a setup step): <!-- macOS/Linux/Windows; bash/PowerShell -->

## Which doc describes the intended behavior?

<!-- Link the runbook/setup guide/design section this contradicts, if any. Helps confirm it's a bug vs. a doc gap. -->
