#!/usr/bin/env bash
# Restore Actual Budget from a backup archive in Cloudflare R2.
# Usage:
#   ./restore.sh                      # restore the most recent archive
#   ./restore.sh actual-20260601T030000Z.tar.gz   # restore a specific archive
#
# The current data directory is moved aside as actual.bak.<timestamp> before
# extraction, so you can roll back by stopping Actual, swapping directories,
# and restarting.
set -euo pipefail

BUCKET="household-os-backups"
PREFIX="actual-backups"
DATA_DIR_ACTUAL="/mnt/data/actual"
DATA_DIR_COLLEGE="/mnt/data/college"
COMPOSE_DIR="/opt/household-os/actual"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

# Resolve which archive to restore.
if [ $# -eq 1 ]; then
  ARCHIVE_NAME="$1"
else
  log "No archive specified — finding the most recent backup in R2..."
  ARCHIVE_NAME=$(rclone ls --s3-no-check-bucket "r2:${BUCKET}/${PREFIX}/" | sort | tail -n 1 | awk '{print $2}')
  if [ -z "${ARCHIVE_NAME}" ]; then
    echo "ERROR: no archives found in r2:${BUCKET}/${PREFIX}/" >&2
    exit 1
  fi
fi

log "Restoring from: ${ARCHIVE_NAME}"

# List available archives for reference.
echo ""
echo "Available archives in R2:"
rclone ls --s3-no-check-bucket "r2:${BUCKET}/${PREFIX}/" | sort
echo ""
read -r -p "Restore '${ARCHIVE_NAME}' to /mnt/data? This will stop Actual and College services. [yes/N] " CONFIRM
if [ "${CONFIRM}" != "yes" ]; then
  echo "Aborted."
  exit 0
fi

# Download the archive.
TMPFILE="/tmp/${ARCHIVE_NAME}"
log "Downloading archive..."
rclone copy --s3-no-check-bucket "r2:${BUCKET}/${PREFIX}/${ARCHIVE_NAME}" /tmp/
log "Downloaded to ${TMPFILE}"

# Stop containers.
log "Stopping Actual and College containers..."
docker compose -f "${COMPOSE_DIR}/docker-compose.yml" stop actual-server actual-mcp college-app 2>/dev/null || \
  docker compose -f "${COMPOSE_DIR}/docker-compose.yml" stop actual-server college-app

# Move current data directories aside.
BACKUP_TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_ASIDE_ACTUAL="/mnt/data/actual.bak.${BACKUP_TIMESTAMP}"
BACKUP_ASIDE_COLLEGE="/mnt/data/college.bak.${BACKUP_TIMESTAMP}"
if [ -d "${DATA_DIR_ACTUAL}" ]; then
  mv "${DATA_DIR_ACTUAL}" "${BACKUP_ASIDE_ACTUAL}"
  log "Existing actual data moved aside: ${BACKUP_ASIDE_ACTUAL}"
fi
if [ -d "${DATA_DIR_COLLEGE}" ]; then
  mv "${DATA_DIR_COLLEGE}" "${BACKUP_ASIDE_COLLEGE}"
  log "Existing college data moved aside: ${BACKUP_ASIDE_COLLEGE}"
fi

# Extract the backup (contains both 'actual/' and 'college/' directories).
log "Extracting archive..."
tar -xzf "${TMPFILE}" -C /mnt/data
rm -f "${TMPFILE}"
log "Extraction complete"

# Restart.
log "Starting containers..."
docker compose -f "${COMPOSE_DIR}/docker-compose.yml" start actual-server actual-mcp college-app 2>/dev/null || \
  docker compose -f "${COMPOSE_DIR}/docker-compose.yml" start actual-server college-app

# Brief wait for the health check.
sleep 5
docker compose -f "${COMPOSE_DIR}/docker-compose.yml" ps

log "Restore complete. To roll back:"
log "  1. Stop containers: docker compose stop actual-server actual-mcp college-app"
log "  2. Restore backup directories:"
log "     mv ${DATA_DIR_ACTUAL} /mnt/data/actual.trash && mv ${BACKUP_ASIDE_ACTUAL} ${DATA_DIR_ACTUAL}"
log "     mv ${DATA_DIR_COLLEGE} /mnt/data/college.trash && mv ${BACKUP_ASIDE_COLLEGE} ${DATA_DIR_COLLEGE}"
log "  3. Start containers: docker compose start actual-server actual-mcp college-app"
