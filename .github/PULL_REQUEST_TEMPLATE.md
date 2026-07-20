<!--
Thanks for the change! Fill in the sections below. Delete any that don't apply.
See CONTRIBUTING.md for conventions and AGENTS.md if you're an AI agent.
-->

## Summary

<!-- What does this change do, and why? Link the design-doc section or ADR if relevant. -->

## Area

<!-- Check all that apply. -->

- [ ] `infra/terraform/` (cloud provisioning)
- [ ] `infra/actual/` (Actual + Caddy stack / backups)
- [ ] `infra/college/` (college fund calculator)
- [ ] `docs/` (setup guides / runbooks / design / ADRs)
- [ ] Repo meta (README, CONTRIBUTING, AGENTS, templates)

## How was this tested?

<!--
State what you actually ran and observed. Examples:
- terraform fmt -check && terraform validate; reviewed plan
- docker compose config; docker compose up -d && docker compose ps (healthy)
- npm install && npm start; exercised the affected UI path
- followed the runbook end-to-end
Note anything you could NOT verify (e.g. steps needing live Cloudflare/Hetzner credentials).
-->

## Docs updated

<!-- Infra changes must update the matching install-*.md / runbook-*.md in this same PR. -->

- [ ] Updated the relevant runbook/setup guide, or N/A (no infra behavior changed)
- [ ] Added/updated an ADR in `docs/decisions/` (only if this is a non-obvious decision)
- [ ] Kept `*.example` files in sync with any new variable/secret

## Checklist

- [ ] No secrets committed (`*.tfvars`, `*.env`, `*.key`, `certs/`, state files are gitignored)
- [ ] Commits follow Conventional Commits (`type(scope): summary`)
- [ ] Change is scoped and consistent with `docs/design-doc`
- [ ] Did **not** add/duplicate COOP/COEP headers in the Caddyfile
