# Installing Actual Budget for Household OS

This walks you through deploying a self-hosted **Actual Budget** instance to a cloud server,
locked behind Cloudflare Access (Google login), with TLS and automated backups — starting
from zero accounts and zero tooling.

**What you'll end up with:** Actual Budget running at `https://budget.yourdomain.com`,
accessible only to the Google accounts you allowlist, ready for the finance worker to read
from later.

**Estimated time:** 60–90 minutes for a first-timer.

**Monthly cost:** ~$8–10 (Hetzner `cpx21` VPS in US East + volume + IPv4). Cloudflare's free plan covers
everything on the Cloudflare side. R2 storage for backups is free up to 10 GB.

**Architecture at a glance:**
```
Browser → Cloudflare Access (Google login) → Cloudflare proxy → Caddy (TLS) → Actual Budget
                                                                      ↑
                                                        Hetzner VPS + persistent volume
```

---

## Part 0 — What's in this repo

```
infra/
  terraform/         # provisions: Hetzner VPS, volume, firewall, Cloudflare DNS/Access/Origin-cert/R2
  actual/            # docker-compose.yml + Caddyfile for Actual + Caddy containers
docs/
  install-actual.md  # this file
```

Terraform creates all the cloud resources. You then SSH into the VPS, copy the Docker stack,
and start it up. Actual Budget runs in Docker. Caddy (also in Docker) handles TLS.

---

## Part 1 — Create your accounts

### 1a. Cloudflare

1. Go to **cloudflare.com** → Sign up for a free account.
2. From the dashboard, click **Add a site** and enter your domain name.
3. Follow the prompts — Cloudflare will give you two nameserver addresses (e.g.
   `ada.ns.cloudflare.com`). Log in to your domain registrar and **replace** the existing
   nameservers with the two Cloudflare gives you. This can take up to 24 hours to propagate,
   but usually finishes in under an hour.
4. Wait until the Cloudflare dashboard shows your domain with a **green "Active"** status.

**Enable R2 (Cloudflare's object storage for backups):**

5. In the left sidebar, go to **R2 Object Storage**.
6. Click **Get started** (you'll be asked to add a payment method — R2 has a free tier
   (10 GB/month) but requires a card on file to activate).

**Enable Zero Trust (for the Access login gate):**

7. In the left sidebar, click **Zero Trust**.
8. If prompted, choose a team name (e.g. `household`) and pick the **Free** plan.

### 1b. Hetzner Cloud

1. Go to **hetzner.com/cloud** → Sign up.
2. After email verification, go to your **Hetzner Cloud Console** → **New Project**.
3. Name it something like `household-os` and create it. You'll be inside this project for
   all subsequent Hetzner steps.

---

## Part 2 — One-time Cloudflare console setup

These two steps must be done in the Cloudflare UI — Terraform can't do them for you.

### 2a. Add Google as a login method in Zero Trust

This lets Cloudflare Access use Google accounts to authenticate users.

1. In Cloudflare, go to **Zero Trust** (left sidebar).
2. Click **Settings** → **Authentication**.
3. Under **Login methods**, click **Add new** → select **Google**.
4. Follow the instructions: you'll need to create a Google Cloud OAuth app.
   - Go to **console.cloud.google.com** → create a project (or use an existing one).
   - Go to **APIs & Services** → **OAuth consent screen**: set it to **Internal** (or
     External if you're the only Google Workspace user), fill in app name and your email.
   - Go to **APIs & Services** → **Credentials** → **Create Credentials** →
     **OAuth client ID** → Application type: **Web application**.
   - In **Authorized redirect URIs**, paste the redirect URI that Cloudflare shows you on
     the Add Google screen (looks like `https://<team>.cloudflareaccess.com/cdn-cgi/access/callback`).
   - Click **Create**. Copy the **Client ID** and **Client Secret**.
   - Paste them back into Cloudflare's "Add Google" form → **Save**.
5. Confirm Google now shows up under Login methods with a green checkmark.

### 2b. Set SSL/TLS encryption mode to Full (strict)

This makes Cloudflare verify the certificate on your server (the Origin certificate Terraform
creates). Without this, TLS is effectively not end-to-end.

1. In Cloudflare, click your domain in the top left to go to the zone dashboard.
2. Go to **SSL/TLS** → **Overview**.
3. Change the encryption mode to **Full (strict)**.

---

## Part 3 — Install local tools

You need these on your laptop/desktop to run the deployment.

### 3a. Terraform

**Mac (Homebrew):**
```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
terraform version   # should print 1.6 or higher
```

**Linux:**
```bash
# Download from https://developer.hashicorp.com/terraform/install
# Or via apt:
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform
```

**Windows:** Download the zip from the Terraform website and add it to your PATH, or use
`winget install HashiCorp.Terraform`.

### 3b. SSH keypair

If you don't already have one:
```bash
ssh-keygen -t ed25519 -C "household-os"
# Press Enter to accept the default path (~/.ssh/id_ed25519)
# Set a passphrase (recommended) or leave blank
```

Your public key is at `~/.ssh/id_ed25519.pub`. You'll paste its contents into
`terraform.tfvars` shortly.

---

## Part 4 — Get your API tokens and IDs

### 4a. Cloudflare Account ID and Zone ID

1. In Cloudflare, click your domain to open its dashboard.
2. Scroll down in the right sidebar. You'll see:
   - **Zone ID** — a 32-character hex string. Copy it.
   - **Account ID** — another 32-character hex string just below it. Copy it.

### 4b. Cloudflare API token

1. Click your profile icon (top right) → **My Profile** → **API Tokens** tab.
2. Click **Create Token** → **Create Custom Token**.
3. Give it a name like `household-os-terraform`.
4. Under **Permissions**, add all of the following (click **Add more** between each):
   - `Zone` / `DNS` / `Edit`
   - `Zone` / `SSL and Certificates` / `Edit`
   - `Account` / `Access: Apps and Policies` / `Edit`
   - `Account` / `Access: Organizations, Identity Providers, and Groups` / `Read`
   - `Account` / `Workers R2 Storage` / `Edit`
5. Under **Zone Resources**, set it to **Include → Specific zone → [your domain]**.
6. Click **Continue to summary** → **Create Token**.
7. **Copy the token now** — Cloudflare will only show it once.

### 4c. Hetzner API token

1. In the Hetzner Cloud Console, go to your project → **Security** (left sidebar) →
   **API Tokens** tab.
2. Click **Generate API Token**.
3. Give it a name like `terraform`, set permissions to **Read & Write**.
4. **Copy the token** — it's also shown only once.

### 4d. Find your current public IP

Terraform locks SSH access to your IP address (so the server isn't open to the world).
```bash
curl -s ifconfig.me
# e.g. 203.0.113.42
```
You'll enter this as `203.0.113.42/32` in `terraform.tfvars`.

---

## Part 5 — Fill in Terraform variables

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
```

Open `terraform.tfvars` in your editor. Fill in every field:

```hcl
# Tokens
hcloud_token        = "..."   # Hetzner API token from Step 4c
cloudflare_api_token = "..."  # Cloudflare API token from Step 4b

# Cloudflare identifiers
cloudflare_account_id = "..."  # Account ID from Step 4a
cloudflare_zone_id    = "..."  # Zone ID from Step 4a

# Your domain
domain            = "yourdomain.com"      # the apex domain on Cloudflare
budget_subdomain  = "budget"              # will create budget.yourdomain.com

# Who can log in through Cloudflare Access
family_emails = [
  "you@gmail.com",
  "partner@gmail.com",
  # add as many as you like
]

# Your SSH public key (so you can SSH into the server)
ssh_public_key = "ssh-ed25519 AAAA... household-os"  # contents of ~/.ssh/id_ed25519.pub

# Your current IP — locks SSH to just your machine
admin_ip_cidr = "203.0.113.42/32"   # replace with output from Step 4d

# Server sizing.
# NOTE: Hetzner's US locations (ash = Ashburn/US-East, hil = Hillsboro/US-West)
# only offer the CPX (AMD) and CCX lines — the cx* (Intel) line is EU-only.
# cpx21 (3 vCPU / 4 GB) is the smallest CPX plan meeting Actual's 4 GB floor.
# For an EU location instead, use server_type = "cx22" with location = "nbg1"/"fsn1"/"hel1".
server_type = "cpx21"
location    = "ash"    # Ashburn, VA (US East). Others: hil (US West), nbg1/fsn1/hel1 (EU), sin
```

`terraform.tfvars` is gitignored and will never be committed — it holds all your secrets.

---

## Part 6 — Provision the infrastructure

### 6a. Set up remote state in HCP Terraform (Terraform Cloud)

State is stored remotely in HCP Terraform — not on your laptop — so it's durable,
versioned, and encrypted (your state contains the Origin cert's private key, so this
matters). Execution stays **local**, so your secrets never leave your machine: plans and
applies run here and read from your local `terraform.tfvars`.

1. Sign up at **app.terraform.io** (free tier is fine). The `cloud {}` block in
   `infra/terraform/versions.tf` is already pointed at org `kstimpert-org`, project
   `household-os`, workspace `household-os`.
2. In the HCP Terraform UI, create the **project** named `household-os` (Projects → New
   project). The project must exist before init; the *workspace* inside it is created
   automatically on first `terraform init`.
3. Authenticate the CLI to HCP Terraform — this stores a token locally:
   ```bash
   terraform login
   # Press "yes", then paste the token it opens in your browser
   ```
4. After your first `terraform init` (below) creates the `household-os` workspace, go to
   the workspace in the HCP Terraform UI → **Settings → General** and set
   **Execution Mode** to **Local**. This keeps plan/apply running on your machine against
   your local `terraform.tfvars` (otherwise TFC tries to run remotely and won't have your
   variables).

### 6b. Init, plan, apply

```bash
# Still in infra/terraform/
terraform init
```

This connects to your HCP Terraform workspace and downloads the Hetzner, Cloudflare, and
TLS providers (~30 seconds).

```bash
terraform plan
```

Review the output. You should see it plans to create:
- 1 Hetzner VPS (`cx22`)
- 1 Hetzner volume (10 GB, formatted ext4)
- 1 Hetzner firewall (allows HTTP/HTTPS from anywhere, SSH only from your IP)
- 1 Cloudflare DNS A record (`budget.yourdomain.com` → server IP)
- 1 Cloudflare Access application + policy (Google login, your family_emails list)
- 1 Cloudflare Origin certificate (15-year TLS cert for Caddy to use)
- 1 Cloudflare R2 bucket (for Actual backups)

If the plan looks right:

```bash
terraform apply
# Type "yes" when prompted
```

This takes about 2 minutes. The VPS cloud-init script (which installs Docker) runs in the
background after the server boots — wait an extra 2–3 minutes before SSHing in.

Capture the outputs you'll need:

```bash
terraform output server_ipv4            # note this IP
terraform output budget_url             # note this URL
terraform output -raw origin_cert_pem > /tmp/origin.pem
terraform output -raw origin_key_pem  > /tmp/origin.key
```

---

## Part 7 — Deploy the stack to the server

> **Local vs. remote commands (read once):** Commands in Parts 7–11 run in two places.
> Anything using `terraform`/`ssh`/`scp` runs **locally** — shown below for both **bash**
> (macOS/Linux) and **PowerShell 7** (Windows). Everything you type *after* you SSH into the
> server runs in the server's **Linux** shell — type those exactly as written, no matter your
> local shell. PowerShell users: confirm your 1Password agent is serving the key in this same
> session with `ssh-add -l` before connecting.

Set a shell variable for convenience (the server IP):

**bash (macOS/Linux):**
```bash
IP=$(terraform output -raw server_ipv4)
```

**PowerShell 7 (Windows):**
```powershell
$IP = terraform output -raw server_ipv4
```

Wait for cloud-init to finish (Docker is installed on first boot):

**bash (macOS/Linux):**
```bash
# SSH in and check — you may need to wait 2-3 minutes after terraform apply finishes
ssh root@$IP "docker --version"
# Should print: Docker version 27.x.x, build ...
# If you get "command not found", wait another minute and retry
```

**PowerShell 7 (Windows):**
```powershell
# Same command — $IP must be set in this PowerShell session
ssh root@$IP "docker --version"
```

Copy the Docker Compose stack to the server:

**bash (macOS/Linux):**
```bash
scp -r ../actual root@$IP:/opt/household-os/actual
```

**PowerShell 7 (Windows):**
```powershell
# ${IP} braces are required before the ":" so PowerShell doesn't read "$IP:" as a drive;
# the local source path uses a backslash.
scp -r ..\actual root@${IP}:/opt/household-os/actual
```

Create the certs directory and copy in the Origin certificate:

**bash (macOS/Linux):**
```bash
ssh root@$IP 'mkdir -p /opt/household-os/actual/certs'
scp /tmp/origin.pem root@$IP:/opt/household-os/actual/certs/origin.pem
scp /tmp/origin.key root@$IP:/opt/household-os/actual/certs/origin.key
ssh root@$IP 'chmod 600 /opt/household-os/actual/certs/origin.key'
```

**PowerShell 7 (Windows):**
```powershell
# Part 6 wrote the certs to /tmp (Unix-only), so re-export them to a Windows temp path.
# PowerShell 7's ">" writes UTF-8 without a BOM, which Caddy reads fine.
terraform output -raw origin_cert_pem > $env:TEMP\origin.pem
terraform output -raw origin_key_pem  > $env:TEMP\origin.key

ssh root@$IP 'mkdir -p /opt/household-os/actual/certs'
scp $env:TEMP\origin.pem root@${IP}:/opt/household-os/actual/certs/origin.pem
scp $env:TEMP\origin.key root@${IP}:/opt/household-os/actual/certs/origin.key
ssh root@$IP 'chmod 600 /opt/household-os/actual/certs/origin.key'
```

Update the Caddyfile with your actual host (the file ships with the placeholder
`budget.example.com`):

**bash (macOS/Linux):**
```bash
BUDGET_HOST=$(terraform output -raw budget_host)
ssh root@$IP "sed -i 's/budget.example.com/$BUDGET_HOST/' /opt/household-os/actual/Caddyfile"
```

**PowerShell 7 (Windows):**
```powershell
# NOTE: don't name this $HOST — that's a read-only PowerShell automatic variable.
$budgetHost = terraform output -raw budget_host
ssh root@$IP "sed -i 's/budget.example.com/$budgetHost/' /opt/household-os/actual/Caddyfile"
```

Verify the Caddyfile looks right (same single-quoted command in both shells):

```bash
ssh root@$IP 'cat /opt/household-os/actual/Caddyfile'
# Should show your domain in the site block, e.g.:
#   budget.yourdomain.com {
#     reverse_proxy actual-server:5006
#     tls /etc/caddy/certs/origin.pem /etc/caddy/certs/origin.key
#   }
```

---

## Part 8 — Mount the data volume

Actual's data (its SQLite file) must live on the **persistent Hetzner volume** — not the
VPS's root disk, which is ephemeral and would be lost if you ever recreate the server.

SSH into the server (`ssh root@$IP` works identically in bash and PowerShell, as long as
`$IP` is set in that session):

```bash
ssh root@$IP
```

> Everything from here through the end of Part 8 runs **on the server's Linux shell** — type
> it exactly as shown regardless of whether you connected from bash or PowerShell.

Find the volume device ID:

```bash
ls -l /dev/disk/by-id/ | grep HC_Volume
# You'll see something like:
# lrwxrwxrwx ... scsi-0HC_Volume_12345678 -> ../../sdb
```

Mount it (replace the volume ID with the one you found above):

```bash
VOL=/dev/disk/by-id/scsi-0HC_Volume_12345678   # use your actual ID

mkdir -p /mnt/data
mount $VOL /mnt/data
mkdir -p /mnt/data/actual
```

Make the mount survive reboots:

```bash
echo "$VOL /mnt/data ext4 discard,nofail,defaults 0 0" >> /etc/fstab
```

Verify it's mounted:

```bash
df -h /mnt/data
# Should show the 10 GB volume mounted at /mnt/data
```

Exit the SSH session:

```bash
exit
```

---

## Part 9 — Start Actual

SSH back in and start the Docker stack (the `ssh root@$IP` line is local — same in bash and
PowerShell; the `cd`/`docker` lines run on the server):

```bash
ssh root@$IP
cd /opt/household-os/actual
docker compose up -d
```

Check that both services started:

```bash
docker compose ps
# Should show two services with Status "Up":
#   actual_actual-server_1   Up (healthy)
#   actual_caddy_1           Up
```

Watch the logs briefly to confirm a clean start:

```bash
docker compose logs --tail=50 caddy
# Should end with something like: "serving initial configuration"
# No errors about certificate files or port conflicts

docker compose logs --tail=20 actual-server
# Should show the server starting up on port 5006
```

Exit the SSH session:

```bash
exit
```

---

## Part 10 — First-time Actual setup

Open your browser and go to `https://budget.yourdomain.com`.

**You should be redirected to a Cloudflare Access login page.** Sign in with one of the
Google accounts in your `family_emails` list.

After signing in, you land on Actual's own welcome screen.

### 10a. Set the server password

Actual asks you to set a **server password** on first load. This is a shared password used
by anyone (and any automation) that connects directly to the server. It lives *behind*
Cloudflare Access, so it's a second layer of protection, not a public-facing credential.

1. Enter a strong password and confirm it.
2. Store this password somewhere safe — you'll need it later when the finance worker connects.
   A password manager entry like `Actual Budget — server password` works well.

### 10b. Create or import a budget

- **New budget:** Click **Start fresh** and follow the prompts to create your budget file.
- **Existing budget:** Click **Import from Actual** (if migrating from a local Actual install)
  or **Import from YNAB** (if migrating from YNAB).

### 10c. Optional: Enable end-to-end encryption

If you want your budget file encrypted at rest on the server (so that even if someone gets
access to the server files, they can't read your data):

1. In Actual, go to **Settings** → **Encryption**.
2. Enable end-to-end encryption and set an **encryption password**.
3. Store this password separately from the server password — both are needed by automation.
   A password manager entry like `Actual Budget — encryption password` works well.

> **Note:** Once E2E encryption is enabled, the `@actual-app/api` library (used by the
> finance worker later) will need both the server password *and* the encryption password.

### 10d. Set up bank sync (optional but recommended)

Actual supports automatic transaction import via **SimpleFIN** (US) or **GoCardless** (EU/UK).

1. In Actual, go to **Settings** → **Show advanced settings** → **Bank sync**.
2. Follow the instructions for your bank sync provider to link your accounts.

Do this configuration inside Actual — not in Household OS. Actual handles all the OAuth
and refresh token management.

### 10e. Note your Sync ID

The finance worker uses this ID to download your budget.

1. In Actual, go to **Settings** → **Show advanced settings**.
2. Find **Sync ID** — a UUID that looks like `a1b2c3d4-...`.
3. Note it somewhere — you'll need it when setting up the Hub (Phase 2).

### 10f. Using Actual on your other devices — use the browser/PWA, not the native apps

Cloudflare Access only admits **interactive browser logins** (it gates the site behind the
Google SSO redirect, which needs a real browser to complete). The Actual **desktop and mobile
apps connect with direct API calls**, can't perform that SSO, and will report
**"server isn't running"** — they're receiving the Access login page instead of the server.

**Use the web app instead — you lose nothing, including offline use.** Actual is *local-first*:
every client keeps a full local copy of your budget (WASM SQLite in the browser) and the server
only relays changes between devices (see "What Actual actually is" below). So:

1. On each device, open `https://budget.yourdomain.com` in a browser and sign in with Google.
2. Use the browser's **Install app / Add to Home Screen** to install it as a PWA — you get an
   app-like icon and window, offline app-shell loading (service worker), and persistent local
   storage so the browser won't evict your budget copy.
3. Edit offline freely; changes sync to the server and your other devices when you reconnect —
   exactly as a native app would.

> **Sync vs. Access sessions:** offline *editing* is never blocked, but the *sync* channel needs
> a live Access cookie. When it expires (`access_session_duration`, default **1 month** in this
> repo), the next online sync redirects to Google login — just **reload the page** to re-auth and
> sync resumes. If you genuinely need a native app, the only real options are enrolling the device
> in Cloudflare **WARP** or using a service token for header-capable API clients (the GUI apps
> can't send those headers).

---

## Part 11 — Verify the setup

### 11a. Check the secure context

Actual uses WebAssembly + SharedArrayBuffer, which requires a secure context and specific
HTTP headers. In your browser on the Actual page, open **DevTools** (F12) → **Console** tab
and run:

```js
crossOriginIsolated
// Must print: true

typeof SharedArrayBuffer
// Must print: "function"
```

If either is wrong, see Troubleshooting below before continuing.

### 11b. Test the Access gate from a non-allowlisted account

Open an incognito window (or a different browser) and go to `https://budget.yourdomain.com`.
You should hit the Cloudflare Access login page. Try signing in with a Google account
**not** in your `family_emails` list — it should be blocked with an "Access denied" message.

### 11c. Test the data volume persists across restarts

The `ssh root@$IP` line is local (same in bash and PowerShell); the rest runs on the server:

```bash
ssh root@$IP
docker compose restart
docker compose ps    # confirm both services come back Up
exit
```

---

## Part 12 — Backups

Actual's data lives in `/mnt/data/actual` on the server. The weekly backup script in
`infra/actual/backup.sh` briefly pauses the Actual container, archives the data directory,
and uploads it to the R2 bucket Terraform created. A systemd timer fires it every Sunday at
03:00 UTC. Eight weeks of archives are kept; older ones are pruned automatically.

### 12a. Create an R2 API token

This token is separate from your Terraform token — it only needs R2 write access.

1. In Cloudflare, go to **R2 Object Storage** → **Manage R2 API Tokens** → **Create API Token**.
2. Name it `household-os-backup`.
3. Set permissions: **Object Read & Write**, restricted to bucket `household-os-backups`.
4. Click **Create API Token**. Copy the **Access Key ID**, **Secret Access Key**, and note
   your **Account ID** (shown in the R2 dashboard sidebar, or read from `terraform.tfvars`).

### 12b. Install rclone on the server

Set `$IP` if it isn't already (same as Part 6/7):

**bash:**

```bash
IP=$(terraform output -raw server_ipv4)
```

**PowerShell:**

```powershell
$IP = (terraform output -raw server_ipv4).Trim()
```

SSH in and install rclone:

```bash
ssh root@$IP
curl https://rclone.org/install.sh | sudo bash
```

Configure rclone for R2 (replace the three placeholders with the values from step 12a):

```bash
rclone config create r2 s3 \
  provider=Cloudflare \
  access_key_id=<ACCESS_KEY_ID> \
  secret_access_key=<SECRET_ACCESS_KEY> \
  endpoint=https://<ACCOUNT_ID>.r2.cloudflarestorage.com \
  acl=private
```

Verify connectivity (empty output is fine — bucket exists but has no files yet):

```bash
rclone ls r2:household-os-backups/
exit
```

### 12c. Copy the backup and restore scripts to the server

*(Run locally — `$IP` must be set in this shell.)*

**bash:**

```bash
scp ../actual/backup.sh ../actual/restore.sh root@$IP:/opt/household-os/actual/
ssh root@$IP 'chmod +x /opt/household-os/actual/backup.sh /opt/household-os/actual/restore.sh'
```

**PowerShell:**

```powershell
scp ..\actual\backup.sh ..\actual\restore.sh root@${IP}:/opt/household-os/actual/
ssh root@$IP 'chmod +x /opt/household-os/actual/backup.sh /opt/household-os/actual/restore.sh'
```

### 12d. Install the systemd timer

*(On the server — the heredocs below work in bash; copy-paste line by line if your terminal
struggles with the multi-line form.)*

```bash
ssh root@$IP

cat > /etc/systemd/system/actual-backup.service << 'EOF'
[Unit]
Description=Actual Budget weekly backup to Cloudflare R2

[Service]
Type=oneshot
ExecStart=/opt/household-os/actual/backup.sh
StandardOutput=journal
StandardError=journal
EOF

cat > /etc/systemd/system/actual-backup.timer << 'EOF'
[Unit]
Description=Weekly Actual Budget backup

[Timer]
OnCalendar=Sun *-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now actual-backup.timer
systemctl list-timers actual-backup.timer   # confirm: NEXT and LAST columns appear
exit
```

### 12e. Test a manual run

```bash
ssh root@$IP
/opt/household-os/actual/backup.sh
# Prints timestamps + "Backup complete." — total pause time is under 1 second

rclone ls r2:household-os-backups/actual-backups/
# Should show the new .tar.gz with its size and name
exit
```

### 12f. Volume snapshots (coarse safety net)

In the Hetzner Cloud console, go to your volume → **Snapshots** → **Take snapshot** before
any major operation (server rebuild, destructive `terraform apply`).

### 12g. Exercise a restore before you need it

The restore script (`restore.sh`) stops Actual, moves the current data directory aside
as `actual.bak.<timestamp>`, extracts the chosen backup, and restarts. Run it on the server:

```bash
ssh root@$IP

# List backups and restore the most recent one:
/opt/household-os/actual/restore.sh

# Or restore a specific archive by name:
/opt/household-os/actual/restore.sh actual-20260601T030000Z.tar.gz
```

The script prompts for confirmation before touching anything. If the restore looks wrong,
roll back with the command it prints at the end (swap the `.bak.` directory back).

> **Note on the UI export format:** The backup and restore scripts operate on Actual's raw
> server data directory — not the `.zip` you get from Settings → Export. These are not
> interchangeable: use the UI export if you want to migrate to a new Actual instance or
> share a budget; use the scripts when recovering this server from failure.
>
> Litestream (for point-in-time recovery) is set up later with the Hub's SQLite database
> in Phase 2, not with Actual's SQLite file.

---

## Part 13 — OS security updates (automatic)

`unattended-upgrades` is configured in cloud-init and requires no manual setup. It:

- Installs Ubuntu security patches daily
- Reboots automatically at **03:30 UTC** when a kernel update requires it — 30 minutes after the backup window, so containers restart cleanly under `restart: unless-stopped`

To verify it's active on the server:

```bash
ssh root@$IP
systemctl status unattended-upgrades
# Should show: active (running)

cat /var/log/unattended-upgrades/unattended-upgrades.log | tail -20
# Shows recent patch activity
```

If you rebuild the server from scratch, this is wired in via cloud-init — no manual step needed.

**Already have a running server?** See [`docs/runbook-os-updates.md`](runbook-os-updates.md) §1 for the one-time backfill steps. That runbook also covers manual updates, checking patch history, and troubleshooting.

**Updating Actual Budget itself** (the app, not the OS) is a separate procedure — pulling a
new container image and recreating it, with a full rollback plan and a caveat about the MCP
server. See [`docs/runbook-actual-updates.md`](runbook-actual-updates.md).

---

## What Actual actually is (read this if something seems wrong)

Two facts about Actual that affect everything:

1. **There is no REST API.** Actual's server is a *sync store only* — it holds your data
   but can't answer budget queries. All budget logic lives in the **`@actual-app/api`
   Node.js library**, which downloads a local copy and answers queries from that copy.
   The finance worker (Phase 2) doesn't "hit an Actual endpoint" — it runs the Node library.

2. **It needs a secure context + COOP/COEP headers** to use SharedArrayBuffer (its WASM
   SQLite engine). That means HTTPS end-to-end and **not duplicating** those headers at the
   proxy level. The `Caddyfile` in this repo is specifically written to let Actual set them
   and not re-add them — duplicating them causes `SharedArrayBufferMissing`, the #1 self-host
   failure mode.

---

## How the finance worker will connect (Phase 2 preview)

When the Hub backend exists, it will call the **Actual HTTP REST API sidecar**
(`actual-http-api`) over the internal Docker network. The sidecar wraps `@actual-app/api`
and exposes it as plain REST, so the Hub can be written in any language (Python/FastAPI)
without embedding the Node library in-process. See `docs/install-actual-http-api.md` for
the sidecar setup.

```python
import httpx

# Calls the sidecar over the internal Docker network — no Cloudflare Access in the way.
resp = httpx.get(
    f"http://actual-http-api:5007/v1/budgets/{SYNC_ID}/months/2026-06/categories",
    headers={"X-Api-Key": API_KEY},
    timeout=10,
)
categories = resp.json()["data"]
overspent = [c for c in categories if c["balance"] < 0]
```

The Hub never calls write endpoints — the design forbids write-back to Actual.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `SharedArrayBufferMissing` / blank white app | COOP/COEP headers missing or **duplicated** at the proxy | Don't set these headers in Caddy — let Actual set them. Confirm `crossOriginIsolated === true` in the browser console. Check that Cloudflare isn't stripping them. |
| Browser cert warning / Cloudflare 526 error | SSL mode not *Full (strict)*, or cert/key mismatch on the server | Set zone SSL to **Full (strict)** in Cloudflare. Re-copy `origin.pem`/`origin.key` from `terraform output`. |
| Cloudflare Access login page loops forever or never appears | Google IdP not added in Zero Trust, or DNS not proxied through Cloudflare | Check Zero Trust → Settings → Authentication for the Google IdP. Confirm the DNS record is **orange-clouded** (proxied), not grey. |
| Cloudflare shows "Access denied" even for allowed emails | Email not in `family_emails`, or wrong capitalization | Double-check the email in `terraform.tfvars`; run `terraform apply` after changing it. |
| Finance worker (Phase 2) gets 403 or redirect to Access login | Worker is hitting the public URL instead of internal network | Point the worker at `http://actual-server:5006` on the Docker internal network, not the public domain. |
| Actual **desktop/mobile app** says "server isn't running" | Cloudflare Access only admits interactive **browser** SSO; native apps can't complete Google login and receive the Access login page | Use the **web app / PWA** in a browser instead — fully local-first, see Part 10f. Or enroll the device in Cloudflare **WARP**. A service token only helps header-capable API clients, not the GUI apps. |
| Web/PWA stops syncing after a while (still works offline, won't push/pull) | Access session expired, so sync requests get redirected to the login page | **Reload the page** to re-auth via Google; sync resumes. To re-login less often, raise `access_session_duration` (default 1 month) and `terraform apply`. |
| Can't SSH to the server | `admin_ip_cidr` is stale (your home IP changed) | Find your new IP (`curl ifconfig.me`), update `terraform.tfvars`, run `terraform apply`. Or temporarily allow all IPs via the Hetzner firewall console if you're locked out. |
| `docker compose up` fails: port already in use | Another process on port 443 or 5006 | `ss -tlnp | grep 443` to find what's using it; kill it or remove it. |
| Volume not found (`/dev/disk/by-id/` shows no HC_Volume) | Cloud-init hasn't finished attaching it yet | Wait 2 minutes and recheck. Hetzner attaches volumes after the server is booted. |

---

## What this does and doesn't cover

**Covered (Phase 1):** Actual running, gated by Cloudflare Access, TLS-correct end-to-end,
data on persistent storage, backup strategy in place.

**Deferred to later phases:**
- Hub backend (Phase 2): Node server, finance worker, Litestream for the Hub's SQLite
- Home-side Cloudflare Tunnel for Home Assistant bridge
- Playwright/Whole Foods automation
- E-ink panel and narrow device token
- Meal planner

All of these will run on this same VPS and Cloudflare account — Phase 1 is the foundation.
