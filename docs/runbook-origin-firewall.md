# Runbook: origin firewall (Cloudflare-only 80/443)

**What:** The Hetzner firewall (`hcloud_firewall.hub`) admits `tcp/80` and `tcp/443` **only from
Cloudflare's published IP ranges**, so nobody can bypass Cloudflare Access by sending requests
straight to the origin IP. See [ADR-0007](decisions/0007-origin-cloudflare-only.md).
**Controlled by:** `restrict_origin_to_cloudflare` in `infra/terraform/terraform.tfvars` (default `true`)
**Ranges from:** the `cloudflare_ip_ranges` data source, read live on every `terraform plan`
**Verify:** a direct `curl --resolve` to the origin IP times out; the same hostname through Cloudflare still answers
**Not affected:** admin SSH / Tailscale ([install-tailscale.md](install-tailscale.md)), the Caddyfile, the containers

---

## 1 — Roll out on an existing deployment

Do this once, on a box that was set up before the change (80/443 open to `0.0.0.0/0`). Nothing on
the server changes. It's a Terraform-only, in-place firewall update.

### 1a. Record the "before" state (optional, but proves the fix)

From your admin machine (any non-Cloudflare network). The examples use the budget host; any
other site hostname works the same way.

**bash (macOS/Linux):**
```bash
IP=$(cd infra/terraform && terraform output -raw server_ipv4)
SITE=$(cd infra/terraform && terraform output -raw budget_host)

# Today this reaches Caddy directly, skipping Access. Expect an HTTP status (e.g. 200).
curl -sk -o /dev/null -w '%{http_code}\n' --max-time 8 --resolve "$SITE:443:$IP" "https://$SITE/"
```

**PowerShell 7 (Windows):**
```powershell
$IP = terraform -chdir=infra/terraform output -raw server_ipv4
$SITE = terraform -chdir=infra/terraform output -raw budget_host

# Use curl.exe (ships with Windows 10+), not the PowerShell `curl` alias.
# Today this reaches Caddy directly, skipping Access. Expect an HTTP status (e.g. 200).
curl.exe -sk -o NUL -w "%{http_code}`n" --max-time 8 --resolve "${SITE}:443:${IP}" "https://$SITE/"
```

### 1b. Plan and apply

`restrict_origin_to_cloudflare` defaults to `true`, so you don't have to edit
`terraform.tfvars`. From `infra/terraform/` (same commands in bash and PowerShell):

```bash
terraform fmt -check
terraform validate
terraform plan      # READ IT — see below
terraform apply     # only after the plan looks exactly like the description below
```

What the plan should show:

- `data.cloudflare_ip_ranges.edge[0]` is read (no resource for it; it's a lookup).
- **`hcloud_firewall.hub` will be updated in-place**: the `80` and `443` rules change their
  `source_ips` from `0.0.0.0/0, ::/0` to Cloudflare's list (about 15 IPv4 + 7 IPv6 CIDRs,
  e.g. `173.245.48.0/20`, `2400:cb00::/32`). Cross-check against
  <https://www.cloudflare.com/ips-v4> and <https://www.cloudflare.com/ips-v6> if you like.
- The `22` (or `41641`) rule is **unchanged**.
- **Nothing else changes.** If the plan wants to replace `hcloud_server.hub` or touch any
  DNS/Access/cert resource, stop and investigate. That's unrelated drift, not this change.

### 1c. Verify

**bash (macOS/Linux):**
```bash
# 1. Direct-to-origin is now dropped. Expect "000" and curl exit code 28 (timeout).
curl -sk -o /dev/null -w '%{http_code}\n' --max-time 8 --resolve "$SITE:443:$IP" "https://$SITE/"; echo "exit: $?"

# 2. Through Cloudflare still works. Expect a 302 to <team>.cloudflareaccess.com (the Access login).
curl -sI --max-time 10 "https://$SITE/" | grep -iE '^(HTTP|location)'

# 3. SSH is unaffected (whichever path you use today).
ssh root@$IP 'echo ok'          # or: ssh root@household-os  (tailnet-only boxes)
```

**PowerShell 7 (Windows):**
```powershell
# 1. Direct-to-origin is now dropped. Expect "000" and curl exit code 28 (timeout).
curl.exe -sk -o NUL -w "%{http_code}`n" --max-time 8 --resolve "${SITE}:443:${IP}" "https://$SITE/"; "exit: $LASTEXITCODE"

# 2. Through Cloudflare still works. Expect a 302 to <team>.cloudflareaccess.com (the Access login).
curl.exe -sI --max-time 10 "https://$SITE/" | Select-String -Pattern '^(HTTP|location)'

# 3. SSH is unaffected (whichever path you use today).
ssh root@$IP 'echo ok'          # or: ssh root@household-os  (tailnet-only boxes)
```

Then load each site once in a browser (`money.*`, `college.*`, the apex, and the MCP connector in
Claude). Every one should behave exactly as before. Spot-check the hosts without an Access app
too. They have no Access redirect, so check with each one's own token:
`mcp-budget.*` per [mcp-budget-server.md](mcp-budget-server.md), and `actual-api.*` per
[install-actual-http-api.md](install-actual-http-api.md).

---

## 2 — Debugging the origin directly

You can no longer reach Caddy from the public internet without Cloudflare. That's the point.
To bypass Cloudflare deliberately (e.g. to tell a Caddy problem from an edge problem), go
**over the tailnet**. Hetzner's cloud firewall only filters the public interface, so traffic
arriving on `tailscale0` isn't subject to it. This needs Tailscale set up
([install-tailscale.md](install-tailscale.md)).

**bash (macOS/Linux):**
```bash
TSIP=$(tailscale ip -4 household-os)   # the box's 100.x address
curl -sk -o /dev/null -w '%{http_code}\n' --resolve "$SITE:443:$TSIP" "https://$SITE/"
```

**PowerShell 7 (Windows):**
```powershell
$TSIP = tailscale ip -4 household-os   # the box's 100.x address
curl.exe -sk -o NUL -w "%{http_code}`n" --resolve "${SITE}:443:${TSIP}" "https://$SITE/"
```

Without Tailscale, SSH in and curl Caddy on the box itself:
`ssh root@$IP "curl -sk -o /dev/null -w '%{http_code}\n' --resolve $SITE:443:127.0.0.1 https://$SITE/"`
(same line in PowerShell).

---

## 3 — Keep the Cloudflare ranges current

The data source re-reads Cloudflare's list on every plan, but the firewall only changes when
you **apply**. Cloudflare changes its ranges rarely and announces it ahead of time. If it adds
one and you haven't applied, visitors routed through that range get Cloudflare **522**
("connection timed out") errors.

**Routine check:** whenever you run `terraform plan` for anything (and at least monthly,
alongside [OS updates](runbook-os-updates.md)), look at `hcloud_firewall.hub`:

- **No change** means you're in sync.
- **In-place update to the 80/443 `source_ips` only** means Cloudflare changed its ranges.
  Check the diff against <https://www.cloudflare.com/ips/> and apply.

---

## 4 — Break-glass: reopen 80/443 to the world

Use this only if you must apply some other Terraform change while the Cloudflare ranges API
is unavailable (the plan errors reading `data.cloudflare_ip_ranges.edge`). Or use it if you
suspect the firewall itself and need to rule it out. It **re-exposes the Access bypass**
while it's in effect.

1. In `infra/terraform/terraform.tfvars`:
   ```hcl
   restrict_origin_to_cloudflare = false
   ```
2. `terraform plan` (expect only the 80/443 rules on `hcloud_firewall.hub` to go back to
   `0.0.0.0/0, ::/0`), then `terraform apply`.
3. **Undo it as soon as you can**: delete the line (or set it to `true`), plan, apply, and
   re-run §1c.

If Terraform itself is unavailable, you can edit the rules by hand in the Hetzner Cloud
Console (**Firewalls → household-os-fw**). The next `terraform apply` puts them back.

---

## 5 — Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Cloudflare **522** on some or all sites right after apply | A site's DNS record is **grey-clouded** (DNS-only), so visitors hit the origin directly and get dropped | Every record must be proxied (orange cloud). Terraform manages them that way; re-check any record added by hand in the dashboard. |
| Sporadic **522** from some locations, weeks later | Cloudflare added an IP range you haven't applied yet | §3: `terraform plan` will show the new range on `hcloud_firewall.hub`; apply it. |
| `terraform plan` errors reading `data.cloudflare_ip_ranges.edge` | Cloudflare API outage, or the API token is invalid | Retry later; check the token ([install-actual.md](install-actual.md) §4b). If you must apply something now, use §4. |
| `terraform apply` rejects the firewall update (rule/IP limit) | Hetzner per-firewall limits | Unexpected with about 22 CIDRs. Note the exact error and open an issue. The previous rules stay in place, so nothing breaks. |
| Direct `curl --resolve` to the public IP **still answers** after apply | Apply didn't run, or you tested from inside the tailnet/the box | Check `terraform plan` shows no pending change, and test from a normal network with the **public** IP, not the 100.x address. |
