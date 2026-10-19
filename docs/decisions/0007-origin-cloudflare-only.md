# 0007 — Origin reachable only through Cloudflare (firewall allowlist of Cloudflare IPs)

- **Status:** Accepted (implemented in `infra/terraform/`; on by default)
- **Date:** 2026-10-19
- **Deciders:** Household OS owner
- **Related:** design-doc §4.1 (Cloudflare Access is the auth gate); ADR-0002 / ADR-0005 (MCP
  host has no self-hosted Access app); ADR-0006 (admin SSH, separate plane);
  `infra/terraform/main.tf` (`hcloud_firewall.hub`); `docs/runbook-origin-firewall.md`
- **Sources:**
  [Cloudflare IP ranges](https://www.cloudflare.com/ips/),
  [Authenticated Origin Pulls](https://developers.cloudflare.com/ssl/origin-configuration/authenticated-origin-pull/)

## Context

Every family-facing site (Actual at `money.*`, `college.*`, the apex landing page, and the
planned Hub API under `https://<apex>/api/*`) has **no auth of its own beyond Cloudflare
Access at the edge** (design-doc §4.1). Caddy on the VPS serves Cloudflare Origin certificates
and reverse-proxies to the containers.

The Hetzner firewall, though, opened `tcp/80` and `tcp/443` to `0.0.0.0/0, ::/0`. Anyone who
learns the origin IP (pre-proxy DNS history, an IP leaked in an email or log, or a plain
mass scan of Hetzner's address space) can skip Cloudflare entirely:

```bash
curl -k --resolve money.example.com:443:<origin-ip> https://money.example.com/
```

Caddy routes on SNI/Host, so that request reaches Actual with no Access check at all. The
Origin cert only causes a warning in a browser; `-k` ignores it. For Actual there is still the
shared server password, but the landing page and the Hub API would be fully open, and the
college app has no auth of its own.

`mcp-budget.*` and `actual-api.*` deliberately have no Access app (their gates are app-level
tokens), but they are still orange-clouded, so they also lose the WAF / rate-limiting in front of
those tokens when hit directly.

## Decision

**Restrict the firewall's `tcp/80` and `tcp/443` rules to Cloudflare's published IP ranges.**

- The ranges come from the Cloudflare provider's `cloudflare_ip_ranges` data source
  (`ipv4_cidr_blocks` + `ipv6_cidr_blocks`). That is the same list as
  `https://www.cloudflare.com/ips-v4` / `ips-v6`, read live from the API on every
  `terraform plan`, so no hardcoded list can go stale in the repo.
- A new variable `restrict_origin_to_cloudflare` (default **`true`**) controls it. `false` is the
  break-glass: it restores the old world-open rule and skips the data source, so you can still
  apply other changes if the Cloudflare ranges API is unavailable.
- Admin SSH (`tcp/22` / Tailscale `udp/41641`, ADR-0006) is unchanged.
- Caddy, the Caddyfile (including Actual's COOP/COEP handling) and the containers are
  unchanged.

### Why default ON (unlike ADR-0006's toggle)

ADR-0006 defaults OFF because applying it early could lock the operator out. This change has
no lockout risk. The admin path is SSH/Tailscale, and nothing legitimate reaches 80/443 except
Cloudflare. That includes the box's own calls to its public hostnames, which resolve to
Cloudflare anycast and come back from Cloudflare IPs. Default ON is the secure state with nothing
to verify first.

## Alternatives considered

| Option | Verdict |
|---|---|
| **Firewall allowlist of Cloudflare IPs** (chosen) | Pure Terraform; drops non-Cloudflare packets at Hetzner's network edge before they reach Caddy's TLS stack, so scanners see nothing. No change on the box. The list is kept current by the data source. Failure mode is safe: if the data source can't be read, `plan` errors and nothing is applied. |
| **Authenticated Origin Pulls (mTLS)**, zone-level with Cloudflare's shared cert | Needs `client_auth { mode require_and_verify … }` in **every** Caddy site block (including Actual's, next to the COOP/COEP footgun), the CA PEM distributed to the box and mounted into Caddy, and the zone setting toggled in the right order. If any one of those is wrong, every site breaks. Port 443 stays world-reachable, so Caddy's TLS stack is still exposed to the internet. It also has **the same "any Cloudflare customer" residual as the IP allowlist** (see below), because the shared cert proves "came from Cloudflare," not "came from *our* zone." More moving parts for the same guarantee. |
| **AOP with a per-zone / per-hostname custom client cert** | The only variant that proves "from our zone." It means generating and uploading our own client cert and rotating it, on top of all the Caddy work above. Worth it only if the residual below ever becomes material. Kept as the upgrade path. |
| **Cloudflare Tunnel (`cloudflared`), close 80/443 entirely** | Strongest network posture (no inbound web ports). It re-plumbs every hostname, adds a daemon on the box, and changes how Origin certs / Full (strict) work. A much bigger change than the gap needs. Revisit if the home-side tunnel (design-doc §3) makes `cloudflared` a dependency anyway. |
| **Validate `Cf-Access-Jwt-Assertion` at the origin** | The proper app-layer proof that Access let the request in, and it holds even against the residual below. It needs code in each backend (or a Caddy plugin), and it doesn't apply to the MCP/API hosts, which have no Access app. A good follow-up for the Hub API once it exists. It doesn't replace the network control. |

## Consequences

**Residual risk (stated honestly).** Any Cloudflare account, not just ours, egresses from
these same ranges. An attacker could in principle put their own Cloudflare zone in front of our
origin IP. To reach one of our sites, though, they would also have to make Cloudflare send
**our** SNI and Host (Caddy only answers the exact configured hostnames, and an unknown SNI
fails the TLS handshake). As far as we know, that takes origin-override features Cloudflare
restricts by plan. So this closes the trivial `curl --resolve` bypass and mass scanning, but it
is not a cryptographic proof of origin. Zone-level AOP has the same residual. Per-hostname AOP
or origin-side Access JWT validation (above) are the upgrades if that ever matters.

**Range drift.** Cloudflare changes its ranges rarely and announces it in advance. Until we
re-apply after a change, requests from a new range are dropped. Visitors would see Cloudflare
**522** errors from the affected PoPs only. The runbook makes "`terraform plan` shows no change
to `hcloud_firewall.hub`" a periodic check. A plan diff there means apply.

**Debugging the origin directly** now has to go over the tailnet (ADR-0006). Hetzner's cloud
firewall only governs the public interface, so
`curl --resolve <host>:443:<100.x tailnet IP>` still works for the admin. That is an
admin-only path, not a family bypass.

**Hetzner rule size.** The two web rules now carry about 22 CIDRs each instead of 2. That
should be well within Hetzner's per-firewall limits, but it can only be confirmed by a live
apply. Hetzner rejects the update at apply time if not, and the old rules stay in place.

**When to revisit:** if the Hub API grows write endpoints or anything finance-mutating behind
Access, add origin-side `Cf-Access-Jwt-Assertion` validation. If `cloudflared` arrives for the
home tunnel anyway, reconsider a Tunnel for the VPS too.
