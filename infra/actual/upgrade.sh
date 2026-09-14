#!/usr/bin/env bash
# Helper script to upgrade Actual Budget (actual-server) safely.
# Runs a pre-upgrade backup to Cloudflare R2, records current image info/digest,
# pulls the newest image, recreates the container, and prints health status.
#
# Managed in repo at infra/actual/upgrade.sh and deployed to /opt/household-os/actual/upgrade.sh.
# See docs/runbook-actual-updates.md for the complete upgrade procedure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="${COMPOSE_DIR:-${SCRIPT_DIR}}"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"

SERVICE="actual-server"
SKIP_BACKUP=false

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

usage() {
  cat << EOF
Usage: $(basename "$0") [options]

Options:
  --service <name>   Service to upgrade (default: actual-server)
  --all              Upgrade all services in docker-compose.yml
  --skip-backup      Skip running pre-upgrade backup (backup.sh)
  -h, --help         Show this help message
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service)
      SERVICE="$2"
      shift 2
      ;;
    --all)
      SERVICE=""
      shift 1
      ;;
    --skip-backup)
      SKIP_BACKUP=true
      shift 1
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "ERROR: Unknown option '$1'" >&2
      usage
      ;;
  esac
done

if [ ! -f "${COMPOSE_FILE}" ]; then
  echo "ERROR: docker-compose.yml not found at ${COMPOSE_FILE}" >&2
  exit 1
fi

log "Starting upgrade process..."

# Display current image metadata so the pre-update image digest is recorded in terminal output for rollback tracking
log "Recording current container image details..."
if [ -n "${SERVICE}" ]; then
  docker compose -f "${COMPOSE_FILE}" images "${SERVICE}" || true
else
  docker compose -f "${COMPOSE_FILE}" images || true
fi

# Enforce pre-upgrade backup so data can be restored if the update breaks or migrates file formats
if [ "${SKIP_BACKUP}" = true ]; then
  log "Skipping pre-upgrade backup as requested (--skip-backup)."
else
  if [ -x "${SCRIPT_DIR}/backup.sh" ]; then
    log "Running pre-upgrade backup via backup.sh..."
    "${SCRIPT_DIR}/backup.sh"
    log "Backup step complete."
  else
    echo "ERROR: ${SCRIPT_DIR}/backup.sh not found or not executable at ${SCRIPT_DIR}/backup.sh" >&2
    exit 1
  fi
fi

# Pull latest container image from registry
if [ -n "${SERVICE}" ]; then
  log "Pulling newest image for service: ${SERVICE}..."
  docker compose -f "${COMPOSE_FILE}" pull "${SERVICE}"
else
  log "Pulling newest images for all services..."
  docker compose -f "${COMPOSE_FILE}" pull
fi

# Recreate container with updated image layer
if [ -n "${SERVICE}" ]; then
  log "Recreating container for service: ${SERVICE}..."
  docker compose -f "${COMPOSE_FILE}" up -d "${SERVICE}"
else
  log "Recreating containers for all services..."
  docker compose -f "${COMPOSE_FILE}" up -d
fi

# Print post-update status and initial container logs
log "Post-upgrade container status:"
if [ -n "${SERVICE}" ]; then
  docker compose -f "${COMPOSE_FILE}" ps "${SERVICE}"
  log "Recent logs for ${SERVICE}:"
  docker compose -f "${COMPOSE_FILE}" logs --tail=30 "${SERVICE}"
else
  docker compose -f "${COMPOSE_FILE}" ps
fi

log "Upgrade step finished successfully!"
log "Note: Health check may take up to 60 seconds to switch to 'Up (healthy)'."
log "Verify functionality in browser (e.g., https://budget.yourdomain.com)."
