# 0006 — Admin SSH over Tailscale; close public port 22

- **Status:** Accepted (opt-in scaffolded in `infra/terraform/`; toggle defaults OFF)
- **Date:** 2026-08-03
- **Deciders:** Household OS owner
- **Related:** ADR-0001 (Hetzner VPS — "we own SSH hardening"), design-doc §3.1/§4 (trust
  boundaries), `docs/install-tailscale.md`, `infra/terraform/main.tf` (firewall)

## Context

Admin access to the VPS is SSH, gated by a single Hetzner-firewall rule: `tcp/22` open only
from `admin_ip_cidr` — one static IP in CIDR form. This is the **only** admin-plane control,
and it has two problems:

1. **Brittle.** A residential IP is rarely static. When it changes you're locked out until you
   edit Terraform and re-apply, and the standing temptation is to widen the allowlist (`/24`,
   or worse `0.0.0.0/0` "just for a minute"), which quietly erases the control.
2. **Still public.** Even locked to one IP, `tcp/22` faces the internet: it's in every scan,
   exposed to sshd 0-days, and to spoofing/whitelist-bypass classes of bug.

The family data plane is unaffected by this ADR — Actual and the College app sit behind
Cloudflare Access (ADR-scope of the design doc §4) and never used SSH. The gap is purely the
*administrator's* path to the box. ADR-0001 explicitly accepted "we own SSH hardening" as the
trade for a cheap, full-control VPS; this is us paying that down.

## Decision

Put admin SSH behind **Tailscale** (an authenticated WireGuard mesh) and **close public
`tcp/22` entirely**. Concretely:

- Install the Tailscale package on the box (in `cloud-init.yaml` for future rebuilds, backfilled
  by hand on the current box per `install-tailscale.md`). No auth key is stored — `tailscale up`
  is interactive, so **no secret enters `user_data`**, honoring the golden-rules secret rule.
- A new Terraform variable **`ssh_over_tailscale_only`** (default **`false`**) gates the
  firewall shape: `false` keeps today's `tcp/22`-from-`admin_ip_cidr` rule; `true` removes it
  and opens `udp/41641` so Tailscale can form direct (non-relayed) connections.
- The toggle defaults OFF and is flipped **only after** the operator has verified they can SSH
  in over the tailnet — the ordering that makes lockout self-correcting.
- `admin_ip_cidr` stays required even in tailnet-only mode: it's the break-glass rule you
  restore by flipping the toggle back.

Tailscale's free Personal plan ($0) covers this. Auth reuses the project's existing Google
identity.

## Alternatives considered

| Option | Verdict |
|---|---|
| **Tailscale, close public 22** (chosen) | Authenticated WireGuard; no public SSH surface; free; MagicDNS + optional Tailscale-SSH (key expiry, ACLs); trivial break-glass via Hetzner console. Cost: one more dependency (see below). |
| **Status quo — IP-allowlisted `tcp/22`** | Zero new deps, but keeps both problems above (brittle to IP change, still publicly exposed). The thing we're trying to fix. |
| **Cloudflare Tunnel + WARP for SSH** | Keeps everything in the existing Cloudflare footprint and needs no open inbound port. But it routes admin SSH through `cloudflared` + a browser-based/short-lived cert flow, is heavier to operate for a single box, and couples the admin plane to the same edge as the data plane. Overkill vs. Tailscale for one operator. |
| **Hand-rolled WireGuard** | Same transport as Tailscale with none of the coordination: manual key exchange, no MagicDNS, no ACLs, no console. More to build and maintain for strictly less. |
| **Bastion/jump host** | Another always-on box to run and patch — adds cost and surface, the opposite of the goal. |
| **VPN-for-the-family** | Rejected by design: family access is deliberately clientless (Cloudflare Access + Google SSO, README "Key principles"). This ADR keeps the family off the tailnet — admin plane only. |

## Consequences

**Accepted trade-offs:**

- **New dependency (Tailscale + its control plane).** Mitigated: the Hetzner web console is an
  out-of-band, SSH-independent recovery path (`install-tailscale.md` §7), and flipping the
  toggle back reopens `tcp/22` from `admin_ip_cidr`. So a Tailscale outage degrades to
  "recover via console or break-glass," never a hard lockout.
- **Node-key expiry is a footgun on an always-on server** — an expired key silently breaks
  unattended SSH. The runbook calls for disabling key expiry on the *server* node (while
  leaving it on for laptops/phones).
- **A WireGuard UDP port is now exposed** when tailnet-only. This is safe: `tailscaled` drops
  anything that isn't a valid authenticated peer; it does not admit unauthenticated traffic to
  the host.
- **One more package to keep current** — deliberately installed via apt so `unattended-upgrades`
  patches it alongside the OS, rather than a `curl | sh` install we'd have to hand-update.

**Why default OFF:** enabling it changes how the operator reaches the box, and applying it
before Tailscale is verified would lock out the public path. Default-OFF + the "verify then
flip" ordering keeps the change safe and reversible, matching how the MCP auth toggles are
gated (ADR-0003/0005).

**When to revisit:** if the household ever wants more than one admin, or to reach internal
service ports routinely, formalize a Tailscale ACL policy (and possibly tailnet groups) rather
than leaning on `autogroup:owner`/`autogroup:self`.
