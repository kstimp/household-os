# Installing Actual Budget for Household OS

This is the **Phase 1 (finance)** setup from the roadmap (`design-doc` §7): stand up
the cloud box, put Cloudflare Access in front, and get a self-hosted **Actual Budget**
running at `budget.<your-domain>` — ready for the finance worker to read from later.

It follows the architecture decided in `design-doc` §2.4 / §3:

- **Compute:** one always-on **Hetzner Cloud VPS** running Docker (Actual now; the Hub,
  Playwright, and cron later). Cloudflare *can't* be the compute layer — Workers were
  rejected in §3.1 because they can't run a long-lived headless browser or persistent SQLite.
- **Edge:** **Cloudflare** in front — proxied DNS, **Access** (Google SSO + family
  allowlist), an **Origin certificate** for TLS, and an **R2** bucket for backups.
- **TLS on the box:** **Caddy** terminates TLS using the Cloudflare Origin cert and
  reverse-proxies to Actual. Cloudflare SSL mode is **Full (strict)**.

> The Cloudflare **Tunnel** mentioned elsewhere in the design is a *separate* thing for the
> home-side Home Assistant bridge — not used for this cloud box. Here the box has a public
> IP and Cloudflare proxies in front of it.

Everything in `infra/` is Terraform + Docker config you can apply directly.

```
infra/
  terraform/         # Hetzner VPS + volume + firewall + Cloudflare DNS/Access/Origin-cert/R2
  actual/            # docker-compose.yml + Caddyfile for the Actual container
```

---

## What Actual actually is (read this first)

Two facts about Actual change how we install and integrate it:

1. **There is no REST API.** Actual's server is a *dumb sync store* — it can't compute a
   budget. All budget logic lives in the **`@actual-app/api` Node.js library**, which
   downloads a full local copy of the budget and answers queries like
   `getBudgetMonth('2026-06')` from that copy. So the finance worker (later) doesn't "hit an
   endpoint" — it runs the Node library against a local synced copy. This is why the Hub is
   Node (design-doc §3.1).
2. **It needs a secure context + COOP/COEP headers** to enable SharedArrayBuffer (its WASM
   SQLite). That means HTTPS end-to-end and **not duplicating** those headers at the proxy.
   The provided `Caddyfile` lets Actual set them and does not re-add them — the #1 self-host
   failure (`SharedArrayBufferMissing`) comes from duplicating them.

---

## Prerequisites

- A domain on Cloudflare (zone active, nameservers pointed at Cloudflare).
- Accounts: **Hetzner Cloud**, **Cloudflare** (with R2 enabled once).
- Local tools: `terraform >= 1.6`, `ssh`, and an SSH keypair.
- API tokens:
  - **Hetzner:** Project → Security → API Tokens → *Read & Write*.
  - **Cloudflare:** My Profile → API Tokens → Create, with permissions:
    `Zone:DNS:Edit`, `Zone:SSL and Certificates:Edit`,
    `Account:Access: Apps and Policies:Edit`, `Account:Cloudflare R2:Edit`.
- The IDs Terraform needs: Cloudflare **Account ID** and **Zone ID** (both on the zone's
  Overview page / account home).
- A one-time Cloudflare setup the Terraform assumes is in place:
  - **Zero Trust → Settings → Authentication → add Google** as a login method (so Access
    can do Google SSO). (Cloudflare Access app + policy are created by Terraform; the IdP
    itself is a console step.)
  - **SSL/TLS → Overview → set encryption mode to _Full (strict)_** for the zone.

---

## Step 1 — Fill in Terraform variables

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: tokens, account/zone IDs, domain, family_emails,
# your SSH public key, and admin_ip_cidr (your current IP as a /32).
```

`terraform.tfvars` and all state are gitignored — they hold secrets.

## Step 2 — Apply the infrastructure

```bash
terraform init
terraform plan      # review: 1 VPS, 1 volume, firewall, DNS, Access app+policy, Origin cert, R2 bucket
terraform apply
```

Capture the outputs:

```bash
terraform output server_ipv4
terraform output budget_url
terraform output -raw origin_cert_pem > /tmp/origin.pem
terraform output -raw origin_key_pem  > /tmp/origin.key
```

## Step 3 — Get the Actual stack onto the box

```bash
IP=$(terraform output -raw server_ipv4)

# Copy the compose stack and the Origin cert material.
scp -r ../actual root@$IP:/opt/household-os/actual
ssh root@$IP 'mkdir -p /opt/household-os/actual/certs'
scp /tmp/origin.pem root@$IP:/opt/household-os/actual/certs/origin.pem
scp /tmp/origin.key root@$IP:/opt/household-os/actual/certs/origin.key
ssh root@$IP 'chmod 600 /opt/household-os/actual/certs/origin.key'
```

Edit the host in the Caddyfile to match your domain:

```bash
ssh root@$IP "sed -i 's/budget.example.com/budget.YOURDOMAIN.com/' /opt/household-os/actual/Caddyfile"
```

## Step 4 — Mount the data volume

Hetzner attaches the volume but we mount it explicitly so Actual's data lives on durable
block storage (not the VM's ephemeral disk).

```bash
ssh root@$IP
# Find the volume (Hetzner volumes show up by-id as scsi-0HC_Volume_<id>):
ls -l /dev/disk/by-id/ | grep HC_Volume
VOL=/dev/disk/by-id/scsi-0HC_Volume_XXXXXXXX   # <-- yours

mkdir -p /mnt/data
# The volume was created pre-formatted ext4 by Terraform; just mount it.
mount $VOL /mnt/data
mkdir -p /mnt/data/actual

# Persist the mount across reboots:
echo "$VOL /mnt/data ext4 discard,nofail,defaults 0 0" >> /etc/fstab
```

## Step 5 — Start Actual

```bash
cd /opt/household-os/actual
docker compose up -d
docker compose ps          # both actual-server and caddy should be Up
docker compose logs -f caddy   # watch for a clean start
```

## Step 6 — Verify

1. Visit `https://budget.YOURDOMAIN.com`. You should hit the **Cloudflare Access** login,
   sign in with an allowlisted Google account, then land on Actual's own login.
2. **Check the secure context** — in the browser devtools console on the Actual page:
   ```js
   crossOriginIsolated   // must be true
   typeof SharedArrayBuffer  // must be "function"
   ```
   If either is wrong, you have a header/HTTPS problem — see Troubleshooting.
3. From a *non*-allowlisted account (or incognito), confirm Access **blocks** you.

## Step 7 — Set Actual's server password & create the budget

1. On first load Actual asks you to **set a server password** — this is the single shared
   password layered behind Cloudflare Access (design-doc §2.4). Store it as an integration
   secret (§4.4): it'll be needed by the finance worker.
2. Create a budget (or import). If you enable **end-to-end encryption**, you'll set a
   separate **encryption password** — store that too; the worker needs it to read the file.
3. **Bank linking:** configure **SimpleFIN or GoCardless inside Actual** (Settings → Bank
   sync). Do *not* reimplement this in Household OS (design-doc §2.4).
4. Note the budget's **Sync ID**: Settings → *Show advanced settings* → Sync ID. The worker
   uses this with `downloadBudget()`.

---

## Step 8 — How the finance worker will connect (Phase 1, later)

For reference — this is what the read-only mirror + overspend worker (design-doc §2.4 / §2.5)
will do once the Hub exists. It runs **in the Hub container on the same box**, so it reaches
Actual over the internal Docker network and **bypasses Cloudflare Access** (Access blocks
non-browser clients). Add the Hub service to the same compose network as `actual-server`, then:

```js
// npm i @actual-app/api
import * as api from '@actual-app/api';

await api.init({
  dataDir: '/mnt/data/hub/actual-cache',   // local synced copy, on the durable volume
  serverURL: 'http://actual-server:5006',  // internal network, NOT the public host
  password: process.env.ACTUAL_PASSWORD,   // the server password from Step 7
});

await api.downloadBudget(process.env.ACTUAL_SYNC_ID, {
  password: process.env.ACTUAL_E2E_PASSWORD, // only if E2E encryption is on
});

await api.sync();                          // pull latest before every read
const june = await api.getBudgetMonth('2026-06');
// -> categories, budgeted, spent, balance ... feed widgets + overspend alerts
await api.shutdown();
```

Read-only: never call the `setBudget*` mutators (design-doc §2.6 forbids write-back).
If the Hub is ever **not** Node, you'd instead run `actualpy` (Python) or an
`actual-http-api` sidecar — but §3.1 recommends Node precisely to avoid that.

---

## Step 9 — Backups

- **Actual's data** (`/mnt/data/actual`) is its own SQLite — **Litestream does not cover it**
  (Litestream is for the Hub's SQLite). For Actual, use:
  - a **weekly logical export** from inside Actual (Settings → Export) pushed to the R2
    bucket (`terraform output r2_bucket`), and
  - Hetzner **volume snapshots** as a coarse safety net.
- Wire R2 credentials (R2 → Manage API Tokens) into whatever runs the export. The
  point-in-time Litestream stream is set up later with the Hub, not here.
- **Exercise a restore** at least once — design-doc §5.1 makes this non-negotiable.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `SharedArrayBufferMissing` / blank app | COOP/COEP headers missing or **duplicated** | Don't set them in Caddy — let Actual. Confirm `crossOriginIsolated === true`. Ensure Cloudflare isn't stripping them (it shouldn't on a proxied host). |
| Browser cert warning / 526 from Cloudflare | SSL mode not *Full (strict)*, or Origin cert/key mismatch on the box | Set zone SSL to **Full (strict)**; re-copy `origin.pem`/`origin.key` from the TF outputs. |
| Access login loops or never appears | Google IdP not added in Zero Trust, or DNS not proxied | Add Google under Zero Trust → Authentication; confirm the DNS record is **orange-clouded**. |
| Worker gets 403/redirected to login | It's going through the public host / Access | Point the worker at `http://actual-server:5006` on the internal network. |
| Can't SSH | `admin_ip_cidr` is stale (your IP changed) | Update the var and `terraform apply`, or edit the firewall rule. |

---

## What this does and doesn't cover

**Covered:** Actual running, gated, TLS-correct, backed up, and ready to be read by the Hub.

**Deferred to later phases:** the Hub backend itself, Litestream for the Hub SQLite, the
home-side Cloudflare Tunnel for Home Assistant, Playwright/Whole Foods, and the e-ink panel's
narrow device token. Those build on this same VPS + Cloudflare account.
