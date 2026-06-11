# 0001 — Hosting provider: Hetzner Cloud VPS

- **Status:** Accepted (provider scaffolded in `infra/terraform/`; region and sizing are open sub-decisions — see below)
- **Date:** 2026-06-11
- **Deciders:** Household OS owner
- **Related:** design-doc §3.1 (Infrastructure & Backend), §5.1 (Backups & DR), `infra/terraform/`

## Context

Household OS is a single always-on backend plus a few co-located containers.
The host must satisfy a specific set of hard requirements, and these — not
brand familiarity — drive the choice:

1. **Always-on, long-running process** — cron workers and persistent state, so
   not a request-scoped function platform. (Serverless was already rejected in
   §3.1 for this reason.)
2. **Headless Chromium via Playwright** (Whole Foods cart automation + e-ink
   screenshot rendering) — the biggest sizing driver; wants ~1–2 GB RAM under
   load plus full Chromium dependencies.
3. **Persistent SQLite on a real block volume** + Litestream → Cloudflare R2.
4. **Actual Budget's `@actual-app/api` keeps a full local synced copy** of the
   budget on that same volume — more disk and another long-lived Node process.
5. **Docker multi-container** (Actual + Caddy + Hub) on one internal network so
   the finance worker can sync from Actual over the internal network, bypassing
   Cloudflare Access.
6. **Cheap and predictable** — per the "Low Cost (not zero)" principle (§1).

A key cross-cutting finding: the differentiated, cheap services on the
hyperscalers are their **serverless-native** ones (Lambda/Functions, Fargate,
Cloud Run, Container Apps). Those fit this workload **badly** — Actual is a
stateful sync server (not FaaS-able), and their persistent-storage story for a
scale-to-zero container is network-mounted (EFS / Azure Files / GCS-FUSE /
Filestore), where **SQLite is a corruption hazard**. That funnels any
hyperscaler choice onto its plain VM offering — i.e. "a VPS, but more
expensive" — paying the hyperscaler tax (metered egress, more knobs) without
using anything that justifies it (managed DB, multi-AZ, IAM), none of which a
single-box household app needs.

## Decision

Host on a **Hetzner Cloud VPS** (`cx22`, 2 vCPU / 4 GB) with a persistent
volume, fronted by Cloudflare (DNS proxied, Access for SSO + family allowlist,
R2 for backups). This is what `infra/terraform/` provisions. It is the cheapest
option that meets every hard requirement with full root control and no platform
limits on long-running browsers, persistent volumes, or always-on cron.

## Alternatives considered

Costs are approximate for a comparable **~4 GB always-on box** (the `cx22`
equivalent), USD/month, mid-2026 list prices. Egress excluded except where
noted.

| Option | Spec | ≈ $/mo | Verdict |
|---|---|---|---|
| **Hetzner `cx22`** (chosen) | 2 vCPU / 4 GB + 20 GB vol | **~$5** (incl. 20 TB egress) | ✅ Cheapest box meeting all requirements; first-class Terraform provider |
| DigitalOcean / Linode / Vultr VPS | 2 vCPU / 4 GB | $12–24 | Identical model, 2–4× the price |
| Fly.io | Machine + volume, sized for Chromium | ~$10–25+ | Nice DX, US regions; volumes single-node (no resilience win); pricier |
| Railway | always-on + browser, usage-based | ~$15–40+ | Best DX, but usage billing balloons at 24/7; multi-container + volume awkward |
| AWS Lightsail / EC2 `t4g.medium` | 2 vCPU / 4 GB | ~$24–26 (≈$16 reserved) | "A VPS, pricier"; egress metered |
| GCP Compute Engine `e2-medium` | 2 vCPU / 4 GB | ~$20–25 (sustained-use) | Same; egress metered |
| Azure VM `B2als v2` | 2 vCPU / 4 GB | ~$22–30 (≈$17 reserved) | Same; priciest tier, enterprise value unused |
| Serverless containers (Fargate / Cloud Run / Container Apps) | 1 vCPU / 4 GB always-on + net FS | ~$40–90 | ❌ Poor fit: network-FS + SQLite corruption risk, no scale-to-zero for stateful service |
| True FaaS (Lambda / Cloud/Azure Functions, Vercel, CF Workers) | — | — | ❌ Cannot host a stateful sync server, persistent volume, or always-on cron |
| Home server (full Hub) | own hardware | hardware only | ❌ Residential uptime/IP; §1 already rejects home-primary |

**Egress note:** AWS/GCP/Azure all charge ~$0.08–0.12/GB outbound; Hetzner
bundles 20 TB and Cloudflare R2 egress is free. This is why the backup design
(§5.1) already targets R2 rather than S3/GCS/Blob.

**Net:** Hetzner ~$5 → other VPS $12–24 → hyperscalers $20–30, with no
functional gain at the top end for this workload.

## Consequences

**Accepted trade-offs:**

- **We own OS-level ops** — patching, SSH hardening, Docker, wiring Litestream.
  A managed PaaS would absorb some of this; we trade that for ~4–6× lower cost
  and full control over the headless-browser + persistent-volume requirements.
- **Single box = single point of failure.** Mitigated by §5.1: Litestream
  point-in-time restore to R2, a weekly logical export to a second location, and
  a *tested* restore runbook. Acceptable for a household-scale system.
- **Resizing is cheap insurance.** Hetzner resize is a ~2-min reboot and the
  data volume is separate, so we start at `cx22` (4 GB) and bump to `cx32`
  (8 GB) only if Chromium + Actual + the Hub show memory pressure — no need to
  over-provision up front.

**When this should be revisited:** if the project later wants managed Postgres
(instead of SQLite + Litestream), multi-region resilience, or it becomes part of
an existing hyperscaler footprint (one bill, shared VPC/IAM) — at which point a
hyperscaler's premium starts buying something we actually use.

## Open sub-decisions

- **Region.** The Terraform default is `fsn1` (Falkenstein, Germany). For a US
  household — and US Whole Foods automation — a US Hetzner region (`ash`
  Ashburn VA, or `hil` Hillsboro OR) cuts ~100 ms latency and keeps data
  stateside. Not yet ratified.
- **Sizing.** `cx22` (4 GB) is adequate but tight once Chromium spikes alongside
  Actual + the Hub; `cx32` (8 GB) is the fallback. Start small, resize on
  demand.

## Notes — phased rollout (Actual-only first)

Playwright and cron are *additive*; finance (Actual) can stand up first. Two
ways to start small:

- **Same box, fewer containers (preferred):** run only the Actual container on
  the Hetzner box now; add the Hub / Playwright / cron later as additional
  compose services. **No future migration** — growth is a one-line compose
  change. This is what the current scaffold already deploys.
- **Managed/scale-to-zero for Actual now, migrate later:** Fly.io (volume +
  auto-stop), Render (persistent disk), PikaPods (~$2–3 managed Actual), or
  **GCP `e2-micro`** — the only *perpetual* free tier (1 GB, free forever; AWS
  `t3.micro` and Azure `B1S` are free for 12 months only). Migration later is
  trivial (Actual's state is `/data` + native export; repoint DNS). Caveat: use
  a **real block disk**, never object-storage-FUSE, to avoid SQLite corruption.
