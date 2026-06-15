# Runbook: Actual Budget backups

**Setup:** `docs/install-actual.md` Part 12  
**Scripts:** `infra/actual/backup.sh`, `infra/actual/restore.sh`  
**Storage:** Cloudflare R2 bucket `household-os-backups`, prefix `actual-backups/`  
**Schedule:** Weekly, Sunday 03:00 UTC (systemd timer `actual-backup.timer`)

Backups are raw archives of `/mnt/data/actual/` — not the UI export zip. See the
[note on restore vs. UI import](#backup-format-vs-ui-export) at the bottom.

---

## Backup

### Check timer status

```bash
ssh root@$IP
systemctl list-timers actual-backup.timer
```

Look for a sensible **NEXT** (within 7 days) and **LAST** (within 7 days if one has run).

### Run a backup manually

```bash
ssh root@$IP
/opt/household-os/actual/backup.sh
```

Expected output:
```
[...] Starting backup (timestamp=...)
[+] pause 1/1  ✔ Container actual-actual-server-1 Paused
[...] Archive created: 3.6M
[+] unpause 1/1  ✔ Container actual-actual-server-1 Unpaused
[...] actual-server resumed
[...] Uploaded to r2:household-os-backups/actual-backups/actual-<timestamp>.tar.gz
[...] Backup complete.
```

### List backups in R2

```bash
ssh root@$IP
rclone ls --s3-no-check-bucket r2:household-os-backups/actual-backups/ | sort
```

Eight archives are kept; the oldest is pruned automatically on each run.

### Check backup logs (automated runs)

```bash
ssh root@$IP
journalctl -u actual-backup.service --since "14 days ago"
```

---

## Restore

> **Stop here if Actual is healthy.** Only restore if data is lost or corrupted — not for
> undoing a mis-entered transaction (use Actual's own undo history for that).

### List available backups

```bash
ssh root@$IP
rclone ls --s3-no-check-bucket r2:household-os-backups/actual-backups/ | sort
```

### Restore (most recent)

```bash
ssh root@$IP
/opt/household-os/actual/restore.sh
```

The script lists available archives, prompts for confirmation, then:
1. Stops `actual-server` and `actual-mcp`
2. Moves `/mnt/data/actual/` aside as `actual.bak.<timestamp>`
3. Extracts the chosen archive
4. Restarts both containers
5. Prints a roll-back command at the end

### Restore (specific archive)

```bash
ssh root@$IP
/opt/household-os/actual/restore.sh actual-20260601T030000Z.tar.gz
```

### Verify restore succeeded

After the script exits:

```bash
# Containers should be Up:
docker compose -f /opt/household-os/actual/docker-compose.yml ps

# Actual should respond:
curl -sk https://budget.yourdomain.com | head -c 200
```

Then open the budget in a browser and confirm your data looks right.

### Roll back a failed restore

If the restored data looks wrong, swap back to the previous state. The restore script
prints the exact command — it looks like:

```bash
# Stop Actual:
docker compose -f /opt/household-os/actual/docker-compose.yml stop actual-server actual-mcp

# Swap directories (replace the timestamp with the one from the restore output):
mv /mnt/data/actual /mnt/data/actual.trash
mv /mnt/data/actual.bak.20260615T141833Z /mnt/data/actual

# Restart:
docker compose -f /opt/household-os/actual/docker-compose.yml start actual-server actual-mcp
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Timer never fires / LAST is blank | Timer not enabled | `systemctl enable --now actual-backup.timer` |
| `AccessDenied: CreateBucket` on upload | rclone missing `--s3-no-check-bucket` | Re-copy `backup.sh` from the repo; old version on the server |
| `AccessDenied` on list or upload | R2 token expired or wrong permissions | Recreate the token (Cloudflare → R2 → Manage R2 API Tokens) and re-run `rclone config update r2` |
| Archive is 0 bytes | `/mnt/data/actual/` is empty or volume not mounted | `df -h /mnt/data` — if not mounted, re-mount per install doc §8 |
| Restore: containers don't come back up | Docker compose error | `docker compose logs actual-server` for details |
| Restore: budget opens but data looks stale | Restored an older archive than intended | Roll back (above) and re-restore with the correct archive name |

---

## Backup format vs. UI export

The scripts back up Actual's **raw server data directory**. This is different from the
`.zip` you get from Actual → Settings → Export:

| | Script backup | UI export zip |
|---|---|---|
| Contains | Full server data directory | Budget data in a portable format |
| Restore path | Stop Actual, swap directory, restart | Actual → Settings → Import |
| Use for | Server failure / data loss recovery | Migrating to a new Actual instance |
| Automated | Yes (weekly timer) | No (manual) |

Use the scripts to recover this server. Use the UI export if you ever need to migrate to a
different Actual instance or hand off a budget file.
