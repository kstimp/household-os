#!/usr/bin/env bash
# Weekly Actual Budget backup to Cloudflare R2.
# Pauses actual-server briefly for a consistent SQLite snapshot, archives
# /mnt/data/actual/, uploads to R2, then prunes archives older than $KEEP weeks.
# Managed by the actual-backup systemd timer (see docs/install-actual.md §12).
set -euo pipefail

BUCKET="household-os-backups"
PREFIX="actual-backups"
KEEP=8
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
ARCHIVE="/tmp/actual-${TIMESTAMP}.tar.gz"
COMPOSE_DIR="/opt/household-os/actual"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

log "Starting backup (timestamp=${TIMESTAMP})"

# Pause actual-server for a consistent snapshot (Docker pause is sub-second;
# Caddy and actual-mcp stay up and serve cached data during the pause).
docker compose -f "${COMPOSE_DIR}/docker-compose.yml" pause actual-server
trap 'docker compose -f "${COMPOSE_DIR}/docker-compose.yml" unpause actual-server 2>/dev/null || true' EXIT

tar -czf "${ARCHIVE}" -C /mnt/data actual
log "Archive created: $(du -sh "${ARCHIVE}" | cut -f1)"

docker compose -f "${COMPOSE_DIR}/docker-compose.yml" unpause actual-server
trap - EXIT
log "actual-server resumed"

rclone copy --s3-no-check-bucket "${ARCHIVE}" "r2:${BUCKET}/${PREFIX}/"
log "Uploaded to r2:${BUCKET}/${PREFIX}/actual-${TIMESTAMP}.tar.gz"
rm -f "${ARCHIVE}"

# Prune oldest archives, keeping the last $KEEP.
COUNT=$(rclone ls --s3-no-check-bucket "r2:${BUCKET}/${PREFIX}/" | wc -l)
DELETE=$(( COUNT - KEEP ))
if [ "${DELETE}" -gt 0 ]; then
  log "Pruning ${DELETE} old archive(s) (keeping ${KEEP})"
  rclone ls --s3-no-check-bucket "r2:${BUCKET}/${PREFIX}/" \
    | sort \
    | head -n "${DELETE}" \
    | awk '{print $2}' \
    | while IFS= read -r f; do
        rclone delete --s3-no-check-bucket "r2:${BUCKET}/${PREFIX}/${f}"
        log "Deleted: ${f}"
      done
fi

log "Backup complete."
