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
DATA_DIR="/mnt/data/actual"
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
read -r -p "Restore '${ARCHIVE_NAME}' to ${DATA_DIR}? This will stop Actual. [yes/N] " CONFIRM
if [ "${CONFIRM}" != "yes" ]; then
  echo "Aborted."
  exit 0
fi

# Download the archive.
TMPFILE="/tmp/${ARCHIVE_NAME}"
log "Downloading archive..."
rclone copy --s3-no-check-bucket "r2:${BUCKET}/${PREFIX}/${ARCHIVE_NAME}" /tmp/
log "Downloaded to ${TMPFILE}"

# Stop actual-server (and actual-mcp if running — both use the data volume).
log "Stopping Actual containers..."
docker compose -f "${COMPOSE_DIR}/docker-compose.yml" stop actual-server actual-mcp 2>/dev/null || \
  docker compose -f "${COMPOSE_DIR}/docker-compose.yml" stop actual-server

# Move the current data directory aside.
BACKUP_TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_ASIDE="/mnt/data/actual.bak.${BACKUP_TIMESTAMP}"
if [ -d "${DATA_DIR}" ]; then
  mv "${DATA_DIR}" "${BACKUP_ASIDE}"
  log "Existing data moved aside: ${BACKUP_ASIDE}"
fi

# Extract the backup (archive contains the 'actual/' directory).
log "Extracting archive..."
tar -xzf "${TMPFILE}" -C /mnt/data
rm -f "${TMPFILE}"
log "Extraction complete"

# Restart.
log "Starting Actual containers..."
docker compose -f "${COMPOSE_DIR}/docker-compose.yml" start actual-server actual-mcp 2>/dev/null || \
  docker compose -f "${COMPOSE_DIR}/docker-compose.yml" start actual-server

# Brief wait for the health check.
sleep 5
docker compose -f "${COMPOSE_DIR}/docker-compose.yml" ps

log "Restore complete. To roll back: stop Actual, run 'mv ${DATA_DIR} /mnt/data/actual.trash && mv ${BACKUP_ASIDE} ${DATA_DIR}', then start Actual."
