# Runbook: college fund calculator deployment & updates

**Stack:** Node.js app at `/opt/household-os/college` (built as `college-app` container in `/opt/household-os/actual/docker-compose.yml`)  
**Data:** `/mnt/data/college` (persistent volume containing the SQLite database `data.db`)  
**Backups:** Pauses and backups via `infra/actual/backup.sh` → Cloudflare R2 (weekly/manual)  
**Verify:** `docker compose ps` shows `actual-college-app-1` as `running`  

---

## 1 — Initial deployment checklist

Follow these steps for the first-time setup of the subdomain, certificates, application, and routing.

### 1a. Apply Terraform changes (locally)
Run Terraform from your local machine to create the DNS records, Cloudflare Zero Trust Access configurations, and generated Origin TLS certificates:
```bash
cd infra/terraform
terraform apply
```
When prompted, confirm with `yes`. Note down the outputs and extract the certificates:
```bash
# Retrieve certs from local state and write to temporary files
terraform output -raw college_origin_cert_pem > college-origin.pem
terraform output -raw college_origin_key_pem > college-origin.key
```

### 1b. Prepare VPS directories and copy files
On your local machine, run the following to copy the application code, docker compose configs, and backup scripts to the VPS:
```bash
# Define your server IP (or pull dynamically from terraform output)
IP=$(cd infra/terraform && terraform output -raw server_ipv4)

# Create folders on the VPS
ssh root@$IP "mkdir -p /opt/household-os/college /opt/household-os/actual/certs"

# Copy SSL certificates
scp college-origin.pem root@$IP:/opt/household-os/actual/certs/college-origin.pem
scp college-origin.key root@$IP:/opt/household-os/actual/certs/college-origin.key
ssh root@$IP "chmod 600 /opt/household-os/actual/certs/college-origin.key"

# Clean up local temporary certificate files
rm college-origin.pem college-origin.key

# Sync application source code
scp -r infra/college/* root@$IP:/opt/household-os/college/

# Sync updated deployment configs
scp infra/actual/docker-compose.yml infra/actual/Caddyfile infra/actual/backup.sh infra/actual/restore.sh root@$IP:/opt/household-os/actual/
```

### 1c. Replace domain placeholder and launch
SSH into the VPS, update the placeholder domain in the Caddyfile, build, and launch:
```bash
ssh root@$IP

# Replace college.example.com with the real domain college.stimpert.haus
sed -i 's/college.example.com/college.stimpert.haus/' /opt/household-os/actual/Caddyfile

# Build and start the college fund application
cd /opt/household-os/actual
docker compose build college-app
docker compose up -d

# Check Caddy logs to verify TLS binding and routing
docker compose logs caddy
```

---

## 2 — Applying updates (subsequent releases)

When you make changes to the frontend (`public/`) or backend (`src/`) code and want to deploy them:

```bash
IP=$(cd infra/terraform && terraform output -raw server_ipv4)

# 1. Sync updated files to the VPS (overwriting old files)
scp -r infra/college/* root@$IP:/opt/household-os/college/
scp infra/actual/docker-compose.yml root@$IP:/opt/household-os/actual/

# 2. SSH into VPS, rebuild and restart
ssh root@$IP
cd /opt/household-os/actual

# Rebuild the Docker image
docker compose build college-app

# Re-create only the college-app container (Caddy, actual-server remain online)
docker compose up -d college-app

# Verify it started successfully
docker compose ps college-app
docker compose logs college-app
```

---

## 3 — Rollback & restores

### Data Rollbacks
The SQLite database `/mnt/data/college/data.db` is backed up weekly (and can be backed up manually via `/opt/household-os/actual/backup.sh`) in the unified `household-os-backups` R2 bucket.

To restore both Actual Budget and the College Fund app databases to a previous snapshot, follow the instructions in [`runbook-backups.md`](runbook-backups.md) and run:
```bash
ssh root@$IP
/opt/household-os/actual/restore.sh
```
This script will:
1. Stop `actual-server`, `actual-mcp`, and `college-app`.
2. Move `/mnt/data/actual` and `/mnt/data/college` aside to backups.
3. Extract the chosen unified tar archive.
4. Restart all services.

### Code Rollbacks
To roll back a bad code release:
1. Revert your git commit locally.
2. Follow **§2 — Applying updates** using the reverted codebase.
