# Securing admin SSH with Tailscale

This hardens the **admin plane** of the Household OS VPS. Today, SSH is open on the public
internet at `tcp/22`, locked by the Hetzner firewall to a single IP (`admin_ip_cidr`). That
is brittle — a changing home IP locks you out (or tempts you to widen the allowlist) — and it
still leaves port 22 facing the internet. This guide puts SSH behind **[Tailscale](https://tailscale.com)**,
an authenticated WireGuard mesh, and then **closes public `tcp/22` entirely**.

**What you'll end up with:** the VPS reachable for SSH **only** over your private tailnet
(a `100.x.y.z` address), with no SSH port exposed to the public internet. Family access to
Actual and the College app is **unchanged** — that runs through Cloudflare Access and never
touched SSH.

**Estimated time:** 20–30 minutes.

**Monthly cost:** $0. Tailscale's free **Personal** plan covers up to 100 devices and 3 users —
far more than a household admin needs.

**Scope:** this changes how *you* administer the box. It does **not** change how the family
reaches the apps, and it does **not** put family devices on the tailnet.

```
Before:  you ──(public internet, tcp/22 from admin_ip_cidr)──▶ VPS sshd
After:   you ──(Tailscale / WireGuard, 100.x)──────────────────▶ VPS sshd
         public tcp/22: CLOSED
         family ──▶ Cloudflare Access ──▶ Caddy ──▶ apps   (unchanged)
```

> **Order matters.** You install and verify Tailscale **first**, and only close public SSH
> **after** you've confirmed you can get in over the tailnet. Do the steps in order and you
> can't lock yourself out. See §7 for break-glass recovery if something goes sideways.

---

## Part 0 — Prerequisites

- The VPS is already provisioned and running (you finished [`install-actual.md`](install-actual.md)).
- You can currently SSH in as root: `ssh root@$IP` works.
- You have the server's public IP. From `infra/terraform/`:

  **bash (macOS/Linux):**
  ```bash
  cd infra/terraform
  IP=$(terraform output -raw server_ipv4)
  echo "$IP"
  ```

  **PowerShell (Windows):**
  ```powershell
  cd infra/terraform
  $IP = terraform output -raw server_ipv4
  $IP
  ```

Keep that `ssh root@$IP` session working until the very end — it's your safety line.

---

## Part 1 — Create a Tailscale account (tailnet)

1. Go to **[tailscale.com](https://tailscale.com)** → **Get started**.
2. Sign up with an identity provider — use the **same Google account** you already use for
   this project so there's one identity to reason about. (Tailscale never sees your Google
   password; it uses Google as an OAuth login.)
3. That creates your **tailnet**. Choose the free **Personal** plan when prompted.
4. Leave the admin console open at **[login.tailscale.com/admin](https://login.tailscale.com/admin)** —
   you'll approve the server and (optionally) tune key expiry there.

---

## Part 2 — Install Tailscale on the VPS

New servers get the Tailscale **package** automatically from `cloud-init.yaml` (it installs
the package and daemon but does **not** log in — no auth key lives in cloud-init). The current
box was provisioned before that, so install it once by hand — the same backfill pattern as the
[OS-updates runbook §1](runbook-os-updates.md).

```bash
ssh root@$IP

# Add Tailscale's apt repo (noble = Ubuntu 24.04) and install the package.
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg \
  -o /usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-list \
  -o /etc/apt/sources.list.d/tailscale.list
apt-get update
apt-get install -y tailscale
systemctl enable --now tailscaled
```

> Installing via apt (rather than `curl | sh`) means Tailscale is upgraded by the same
> `unattended-upgrades` that already patches the OS — one less thing to hand-update.

Now bring the node up and join it to your tailnet:

```bash
# Still on the VPS.
tailscale up --hostname household-os
```

This prints a `https://login.tailscale.com/a/...` URL. Open it in your browser, sign in with
the **same Google account** from Part 1, and approve the machine. The command returns once the
node is authenticated.

Confirm it's connected and note the tailnet IP:

```bash
tailscale ip -4        # e.g. 100.101.102.103  — this is the address you'll SSH to
tailscale status       # should show this node as active
exit
```

> **Key expiry.** By default Tailscale expires a node's key every ~180 days, after which it
> must re-authenticate — which would break unattended SSH. For an always-on server this is
> usually undesirable: in the admin console open **Machines → household-os → ⋯ → Disable key
> expiry**. (Leave expiry *on* for your laptop/phone, where it's a good thing.)

---

## Part 3 — Install Tailscale on your admin machine

Put the computer you administer from on the same tailnet.

**macOS:**
```bash
brew install --cask tailscale
open -a Tailscale        # then sign in via the menu-bar icon with the SAME account
```

**Linux (Debian/Ubuntu):**
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up        # opens a browser to sign in with the SAME account
```

**PowerShell (Windows):**
```powershell
winget install --id Tailscale.Tailscale -e
# Launch Tailscale from the Start menu and sign in with the SAME account.
```

After signing in, verify both machines see each other:

```bash
tailscale status
# You should see both "household-os" and this machine listed.
```

MagicDNS is on by default, so the server is also reachable by name as `household-os`
(and `household-os.<your-tailnet>.ts.net`).

---

## Part 4 — Verify SSH over the tailnet (do NOT skip)

This is the gate. Open a **new** terminal (keep the old `ssh root@$IP` session alive) and
connect to the box over its **tailnet** address instead of its public IP:

```bash
# Use the 100.x address from Part 2, or the MagicDNS name:
ssh root@100.101.102.103
#   or
ssh root@household-os
```

If that lands you at a root shell on the VPS, the private path works. **Do not proceed until
this succeeds.** If it hangs or refuses, see §Troubleshooting — your public `ssh root@$IP` is
still open, so you are not locked out.

> **Tip — pin it in your SSH config.** Add to `~/.ssh/config` so `ssh household-os` just works:
> ```
> Host household-os
>     HostName household-os        # MagicDNS name; or the 100.x tailnet IP
>     User root
> ```

---

## Part 5 — Close public SSH

Only now that the tailnet path is proven, remove `tcp/22` from the public internet. This is a
one-line Terraform flip — no manual firewall edits.

1. In `infra/terraform/terraform.tfvars`, set:

   ```hcl
   ssh_over_tailscale_only = true
   ```

2. Review and apply, from `infra/terraform/`:

   ```bash
   terraform fmt -check
   terraform validate
   terraform plan      # READ IT: expect the tcp/22 rule to be removed and a udp/41641
                       # rule added on hcloud_firewall.hub. No other resource should change.
   terraform apply     # only after the plan looks exactly like the above
   ```

   The plan should show an **in-place update** to `hcloud_firewall.hub` — never a
   replacement of `hcloud_server.hub`. If it wants to replace the server, stop and re-check;
   `user_data` drift is already ignored, so a server replacement means something else is wrong.
   If you haven't applied the origin-firewall change yet ([ADR-0007](decisions/0007-origin-cloudflare-only.md)),
   the same in-place update will also narrow the `80`/`443` rules to Cloudflare's IP ranges.
   That's expected; see [runbook-origin-firewall.md](runbook-origin-firewall.md).

3. Confirm the public path is now closed but the tailnet path still works:

   ```bash
   # From your admin machine — this should now TIME OUT (good):
   ssh -o ConnectTimeout=8 root@$IP ; echo "exit: $?"

   # This should still land you on the box:
   ssh root@household-os
   ```

Done. SSH no longer has any public attack surface. `nmap`/Shodan see only the WireGuard UDP
port, which drops anything that isn't a valid, authenticated Tailscale peer. `80`/`443` accept
only Cloudflare's IP ranges ([ADR-0007](decisions/0007-origin-cloudflare-only.md)), so a scan
from anywhere else sees them as filtered.

---

## Part 6 — Optional hardening

These are additive; the baseline above already removes the public SSH surface.

### 6a. Tailscale SSH (identity-based auth, no host keys to manage)

Instead of OpenSSH key auth, let Tailscale authenticate and authorize SSH using tailnet
identity + ACLs. Connections then honor key expiry and can be centrally revoked.

```bash
ssh root@household-os        # get on the box over the tailnet first
tailscale set --ssh          # enable Tailscale SSH on this node
```

Then in the admin console (**Access controls**), scope who may SSH as which user. A minimal
policy that lets only you SSH as root over the tailnet:

```jsonc
{
  "ssh": [
    {
      "action": "accept",
      "src":    ["autogroup:owner"],
      "dst":    ["autogroup:self"],
      "users":  ["root"]
    }
  ]
}
```

With Tailscale SSH enabled you can, if you like, stop managing `~/.ssh` keys for this host —
but keep at least one OpenSSH key working until you've confirmed Tailscale SSH end-to-end.

### 6b. Bind sshd to the tailnet interface (defense in depth)

Even with the cloud firewall closing `tcp/22`, you can have `sshd` refuse to *listen* on the
public interface at all. **Only do this after §5 is verified**, and keep a Hetzner console
session handy (§7) — a typo here is a lockout.

```bash
ssh root@household-os
# Listen only on the tailnet address (from `tailscale ip -4`) and loopback:
printf 'ListenAddress 100.101.102.103\nListenAddress 127.0.0.1\n' \
  > /etc/ssh/sshd_config.d/99-tailscale-only.conf
sshd -t && systemctl restart ssh      # sshd -t validates config before you apply it
```

### 6c. Reach internal admin ports over the tailnet

Handy for one-off admin — e.g. hitting Actual's container port directly without exposing it
publicly. `tailscale serve` publishes a local port to your tailnet only (never the internet):

```bash
ssh root@household-os
tailscale serve --bg 5006     # example: expose a local admin port to the tailnet
tailscale serve status
```

Access it from your admin machine at `http://household-os:5006`. Use `tailscale serve --https`
for TLS. This keeps the app's own container port bound to localhost while still letting you
reach it — no new public DNS record, no Cloudflare app.

---

## Part 7 — Break-glass recovery

If you ever lose the tailnet path (Tailscale outage, key expired, botched §6b), you are not
stuck — Hetzner gives you out-of-band console access that doesn't depend on SSH at all:

1. **Hetzner Cloud Console** → your project → server `household-os` → **>_ Console**. This is a
   VNC session to the box; log in as root at the console prompt.
2. From there you can restart Tailscale (`systemctl restart tailscaled`), re-auth
   (`tailscale up`), or undo a §6b change (`rm /etc/ssh/sshd_config.d/99-tailscale-only.conf
   && systemctl restart ssh`).
3. To temporarily reopen public SSH, set `ssh_over_tailscale_only = false` in
   `terraform.tfvars` and `terraform apply` — that restores the `tcp/22`-from-`admin_ip_cidr`
   rule. (This is why `admin_ip_cidr` stays required even in tailnet-only mode.)

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `tailscale up` prints no URL / hangs | `tailscaled` not running | `systemctl status tailscaled`; `systemctl enable --now tailscaled`, then retry |
| SSH to `100.x` hangs (Part 4) | Node not actually up, or MagicDNS not resolving | `tailscale status` on both ends; use the raw `100.x` IP instead of the name; check both machines are signed into the **same** tailnet |
| SSH to `100.x` refused | `sshd` not listening on that interface | Before §6b it listens on all interfaces — recheck the IP from `tailscale ip -4`. After §6b, the `ListenAddress` may be wrong; fix via Hetzner console (§7) |
| Public `ssh root@$IP` still works after §5 | Plan not applied, or wrong var | `terraform plan` should show the `tcp/22` rule gone; confirm `ssh_over_tailscale_only = true` in `terraform.tfvars` and re-`apply` |
| Everything breaks after ~6 months | Node key expired | Re-auth (`tailscale up` via Hetzner console §7) and **disable key expiry** for the server (Part 2 note) |
| `terraform plan` wants to **replace** the server | Unrelated drift, not this change | Stop. This change only edits `hcloud_firewall.hub` in place; investigate before applying |

---

## What changed in the repo

- `infra/terraform/variables.tf` — new `ssh_over_tailscale_only` (bool, default `false`).
- `infra/terraform/main.tf` — the firewall's `tcp/22` rule is now conditional; a `udp/41641`
  rule is added when tailnet-only.
- `infra/terraform/cloud-init.yaml` — installs the Tailscale package on future rebuilds (no
  auth key = no secret; `tailscale up` stays manual).
- `docs/decisions/0006-tailscale-admin-access.md` — the ADR behind this.
