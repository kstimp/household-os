# Runbook: hub landing page deployment & updates

**Stack:** Static page at `/opt/household-os/landing/public`, served by **Caddy's `file_server`** (no app container) from `/opt/household-os/actual/docker-compose.yml`
**Served at:** the **apex** `stimpert.haus`, behind Cloudflare Access (Google SSO + family allowlist)
**Data:** none (fully static)
**Verify:** `docker compose logs caddy` shows the apex site bound; an authenticated browser load of `https://stimpert.haus` renders the hub

---

## 1 — Initial deployment checklist

First-time setup of the apex DNS record, Origin certificate, Cloudflare Access app, and Caddy routing.

### 1a. Apply Terraform changes (locally)
Creates the apex A record, the Zero Trust Access app + family policy, and the generated Origin TLS cert. Then export the cert/key to temp files.

**bash (macOS/Linux):**
```bash
cd infra/terraform
terraform apply
# Retrieve the apex Origin cert/key from local state
terraform output -raw landing_origin_cert_pem > landing-origin.pem
terraform output -raw landing_origin_key_pem  > landing-origin.key
```

**PowerShell 7 (Windows):**
```powershell
cd infra/terraform
terraform apply
# Retrieve the apex Origin cert/key from local state
terraform output -raw landing_origin_cert_pem > $env:TEMP\landing-origin.pem
terraform output -raw landing_origin_key_pem  > $env:TEMP\landing-origin.key
```

### 1b. Copy files to the VPS

**bash (macOS/Linux):**
```bash
IP=$(cd infra/terraform && terraform output -raw server_ipv4)

# Folders on the VPS
ssh root@$IP "mkdir -p /opt/household-os/landing /opt/household-os/actual/certs"

# Origin cert + key (lock the key down)
scp landing-origin.pem root@$IP:/opt/household-os/actual/certs/landing-origin.pem
scp landing-origin.key root@$IP:/opt/household-os/actual/certs/landing-origin.key
ssh root@$IP "chmod 600 /opt/household-os/actual/certs/landing-origin.key"
rm landing-origin.pem landing-origin.key

# Static site + updated deployment configs
scp -r infra/landing/* root@$IP:/opt/household-os/landing/
scp infra/actual/docker-compose.yml infra/actual/Caddyfile root@$IP:/opt/household-os/actual/
```

**PowerShell 7 (Windows):**
```powershell
$IP = terraform -chdir=infra/terraform output -raw server_ipv4

# Folders on the VPS
ssh root@$IP "mkdir -p /opt/household-os/landing /opt/household-os/actual/certs"

# Origin cert + key (braces around IP prevent drive-letter conflicts)
scp $env:TEMP\landing-origin.pem root@${IP}:/opt/household-os/actual/certs/landing-origin.pem
scp $env:TEMP\landing-origin.key root@${IP}:/opt/household-os/actual/certs/landing-origin.key
ssh root@$IP "chmod 600 /opt/household-os/actual/certs/landing-origin.key"
Remove-Item $env:TEMP\landing-origin.pem, $env:TEMP\landing-origin.key

# Static site + updated deployment configs
scp -r infra\landing\* root@${IP}:/opt/household-os/landing/
scp infra\actual\docker-compose.yml root@${IP}:/opt/household-os/actual/docker-compose.yml
scp infra\actual\Caddyfile root@${IP}:/opt/household-os/actual/Caddyfile
```

### 1c. Replace the apex placeholder & (re)launch Caddy
The Caddyfile ships with an `example.com { … }` apex block. Replace **only** that bare-apex
line — the `^` anchor and the trailing space before `{` keep `sed` from touching the
`*.example.com` subdomain blocks above it.

```bash
ssh root@$IP

# Rewrite ONLY the bare-apex site line (anchored — leaves money./college./… untouched)
sed -i 's/^example.com {/stimpert.haus {/' /opt/household-os/actual/Caddyfile

# Recreate Caddy so it picks up the new ../landing mount + the apex site block
cd /opt/household-os/actual
docker compose up -d caddy

# Confirm the apex site is bound and TLS loaded
docker compose logs caddy | tail -n 40
```

### 1d. ⚠️ Apex DNS caveat — check before/after apply
The zone apex often already carries records Terraform does **not** manage here (an email
provider's `MX`/`TXT`, a Cloudflare redirect rule, or a leftover placeholder `A`/`AAAA`).

- `MX`/`TXT` are different record types and coexist fine with the new proxied `A` — leave them.
- A **pre-existing apex `A`/`AAAA`** (or a redirect/Page Rule sending `stimpert.haus` elsewhere)
  will fight the new record. In the Cloudflare dashboard (DNS → Records), confirm the apex `A`
  now points at the VPS IP and is **Proxied** (orange cloud), and remove/disable any conflicting
  apex `A`/`AAAA` or apex redirect so this record is the one in effect.
- If `terraform apply` errors that the record already exists, `terraform import
  cloudflare_record.landing <zone_id>/<record_id>` the existing one (or delete it in the
  dashboard first), then re-apply.

---

## 2 — Applying updates (subsequent releases)

The page is static — editing `infra/landing/public/` and re-syncing is enough; **no rebuild**.
Caddy serves the mounted files directly, so a fresh `scp` is picked up on the next request
(no container restart needed unless you changed the Caddyfile or the compose mount).

**bash (macOS/Linux):**
```bash
IP=$(cd infra/terraform && terraform output -raw server_ipv4)
scp -r infra/landing/* root@$IP:/opt/household-os/landing/
# Only if you changed Caddyfile / docker-compose.yml:
# scp infra/actual/Caddyfile infra/actual/docker-compose.yml root@$IP:/opt/household-os/actual/
# ssh root@$IP "cd /opt/household-os/actual && docker compose up -d caddy"
```

**PowerShell 7 (Windows):**
```powershell
$IP = terraform -chdir=infra/terraform output -raw server_ipv4
scp -r infra\landing\* root@${IP}:/opt/household-os/landing/
# Only if you changed Caddyfile / docker-compose.yml:
# scp infra\actual\Caddyfile root@${IP}:/opt/household-os/actual/Caddyfile
# scp infra\actual\docker-compose.yml root@${IP}:/opt/household-os/actual/docker-compose.yml
# ssh root@$IP "cd /opt/household-os/actual && docker compose up -d caddy"
```

---

## 3 — Verify & rollback

### Verify
```bash
# Unauthenticated: Cloudflare Access should return a 302 to the Google login (NOT the page).
curl -sI https://stimpert.haus | grep -i location

# Authenticated: open https://stimpert.haus in a browser signed in as an allowlisted
# family account → the hub renders, "Money"/"College Fund" link to their subdomains.
```
If you get a TLS error at the origin, re-check that `landing-origin.pem/.key` landed in
`/opt/household-os/actual/certs/` and that the Caddyfile apex line was actually rewritten
(`grep '^stimpert.haus' /opt/household-os/actual/Caddyfile`).

### Rollback
The page has no data to restore — rollback is purely code:
1. Revert the git commit locally.
2. Re-run **§2 — Applying updates** with the reverted `infra/landing/`.

To pull the apex offline entirely, disable the `Household OS — Hub landing` Access app (or set
the apex DNS record to **DNS-only**/remove it) in the Cloudflare dashboard.
