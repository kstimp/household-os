# Runbook: OS updates and security patches

**Setup:** `infra/terraform/cloud-init.yaml` (automatic on new servers, see §1 for existing servers)  
**Automation:** `unattended-upgrades` — daily security patches, auto-reboot at 03:30 UTC  
**Verify:** `systemctl status unattended-upgrades`

---

## 1 — Backfill on an already-running server

Servers provisioned before this was added to cloud-init need a one-time manual setup.

```bash
ssh root@$IP

# Install unattended-upgrades if not already present
apt-get install -y unattended-upgrades

# Write the enable file
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# Write the local overrides (auto-reboot after the 03:00 backup window)
cat > /etc/apt/apt.conf.d/50unattended-upgrades-local << 'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:30";
EOF

# Verify the service is running
systemctl status unattended-upgrades
# Expected: active (running)

exit
```

---

## 2 — Routine manual update

Run this any time you SSH in for another reason, or when you want to confirm the server is current:

```bash
ssh root@$IP

# Apply all pending updates (security + non-security)
apt-get update && apt-get upgrade -y

# Check if a reboot is required (file exists = reboot needed)
cat /run/reboot-required 2>/dev/null && echo "REBOOT NEEDED" || echo "no reboot needed"

exit
```

If a reboot is needed and you want to do it immediately rather than waiting for 03:30:

```bash
ssh root@$IP
reboot
```

Containers come back automatically under `restart: unless-stopped`. Expect ~30 seconds of downtime. Verify afterward:

```bash
ssh root@$IP
docker compose -f /opt/household-os/actual/docker-compose.yml ps
# All services should show Status "Up"
exit
```

---

## 3 — Check patch history

```bash
ssh root@$IP

# What has unattended-upgrades applied recently
cat /var/log/unattended-upgrades/unattended-upgrades.log | tail -30

# Full dpkg install history
grep " install \| upgrade " /var/log/dpkg.log | tail -30

exit
```

---

## 4 — Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `systemctl status unattended-upgrades` shows inactive | Service not installed or not enabled | Run the backfill steps in §1 |
| No entries in `unattended-upgrades.log` after several days | `20auto-upgrades` file missing or malformed | Check `cat /etc/apt/apt.conf.d/20auto-upgrades`; re-write it from §1 |
| Server rebooted but containers are down | `restart: unless-stopped` not set, or Docker didn't start | `systemctl status docker`; `docker compose -f /opt/household-os/actual/docker-compose.yml up -d` |
| Reboot happened during backup window | Timer overlap (backup at 03:00, reboot at 03:30 — backup should finish in seconds) | Check backup log: `journalctl -u actual-backup.service --since "yesterday"` |
