#!/usr/bin/env bash
# =============================================================================
# scripts/backup.sh — Back up Floci persistent state to a timestamped archive
#
# Usage: ./scripts/backup.sh [--output-dir DIR]
#
# What is backed up:
#   The contents of the floci-data Docker named volume, which holds all
#   simulated AWS resource state when FLOCI_STORAGE_MODE is hybrid, persistent,
#   or wal. The backup is a gzip-compressed tar archive.
#
# What is NOT backed up:
#   In-memory state (when FLOCI_STORAGE_MODE=memory). In that mode, no state
#   survives a container restart and there is nothing durable to back up.
#
# Safety:
#   Backups are taken while the container is running. Floci's hybrid and
#   persistent modes flush to disk continuously. For maximum consistency with
#   the wal mode, consider stopping Floci before backing up critical state.
#   The script warns if the container is running so you can make that choice.
#
# Output:
#   backups/floci-backup-YYYYMMDD-HHMMSS.tar.gz
#   backups/floci-backup-YYYYMMDD-HHMMSS.tar.gz.sha256
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -t 1 ]]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

log_info()    { echo -e "${CYAN}[floci]${RESET} $*"; }
log_success() { echo -e "${GREEN}[floci]${RESET} $*"; }
log_warn()    { echo -e "${YELLOW}[floci]${RESET} $*"; }
log_error()   { echo -e "${RED}[floci] ERROR:${RESET} $*" >&2; }

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
OUTPUT_DIR="${REPO_ROOT}/backups"
VOLUME_NAME="${FLOCI_VOLUME_NAME:-floci-data}"
CONTAINER_NAME="${FLOCI_CONTAINER_NAME:-floci}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_FILENAME="floci-backup-${TIMESTAMP}.tar.gz"
BACKUP_PATH="${OUTPUT_DIR}/${BACKUP_FILENAME}"
CHECKSUM_PATH="${BACKUP_PATH}.sha256"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      shift
      OUTPUT_DIR="${1}"
      BACKUP_PATH="${OUTPUT_DIR}/${BACKUP_FILENAME}"
      CHECKSUM_PATH="${BACKUP_PATH}.sha256"
      ;;
    *)
      log_warn "Unknown option: $1"
      ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
  log_error "Docker is not installed or not in PATH."
  exit 1
fi

if ! docker info &>/dev/null; then
  log_error "Docker daemon is not running."
  exit 1
fi

# Check the volume exists and has content worth backing up
if ! docker volume inspect "${VOLUME_NAME}" &>/dev/null; then
  log_error "Docker volume '${VOLUME_NAME}' does not exist."
  log_error "Run 'make up' first to create the volume, then back up after some use."
  exit 1
fi

# Warn if backing up while Floci is running (not an error — hybrid/persistent
# flush continuously so it is safe; wal users may prefer to stop first)
CONTAINER_STATUS=$(docker inspect --format '{{.State.Status}}' \
  "${CONTAINER_NAME}" 2>/dev/null || echo "not_found")

if [[ "${CONTAINER_STATUS}" == "running" ]]; then
  STORAGE_MODE="${FLOCI_STORAGE_MODE:-hybrid}"
  if [[ "${STORAGE_MODE}" == "wal" ]]; then
    log_warn "Floci is running with FLOCI_STORAGE_MODE=wal."
    log_warn "For maximum consistency, stop Floci before backup: make down"
    log_warn "Continuing with live backup..."
  else
    log_info "Floci is running. Taking live backup (storage mode: ${STORAGE_MODE})."
  fi
elif [[ "${CONTAINER_STATUS}" == "not_found" ]]; then
  log_info "Floci container is not running. Backing up volume at rest."
else
  log_info "Floci container state: ${CONTAINER_STATUS}. Backing up volume."
fi

# ---------------------------------------------------------------------------
# Ensure output directory exists
# ---------------------------------------------------------------------------
mkdir -p "${OUTPUT_DIR}"

# Refuse to overwrite an existing backup (names include seconds; collision is
# extremely unlikely, but guard against it anyway)
if [[ -f "${BACKUP_PATH}" ]]; then
  log_error "Backup file already exists: ${BACKUP_PATH}"
  log_error "Wait one second and retry, or specify a different --output-dir."
  exit 1
fi

# ---------------------------------------------------------------------------
# Perform backup using a minimal Alpine helper container
# The helper mounts the named volume read-only and streams a tar archive.
# ---------------------------------------------------------------------------
log_info "Backing up volume '${VOLUME_NAME}' → ${BACKUP_PATH}"

docker run --rm \
  --volume "${VOLUME_NAME}:/floci-data:ro" \
  alpine:3.21 \
  tar -czf - -C /floci-data . \
  > "${BACKUP_PATH}"

BACKUP_SIZE=$(du -sh "${BACKUP_PATH}" | cut -f1)
log_success "Backup written: ${BOLD}${BACKUP_PATH}${RESET} (${BACKUP_SIZE})"

# ---------------------------------------------------------------------------
# Generate SHA-256 checksum for integrity verification
# ---------------------------------------------------------------------------
if command -v sha256sum &>/dev/null; then
  sha256sum "${BACKUP_PATH}" > "${CHECKSUM_PATH}"
  log_success "Checksum:       ${CHECKSUM_PATH}"
elif command -v shasum &>/dev/null; then
  shasum -a 256 "${BACKUP_PATH}" > "${CHECKSUM_PATH}"
  log_success "Checksum:       ${CHECKSUM_PATH}"
else
  log_warn "sha256sum / shasum not found — skipping checksum generation."
fi

echo ""
log_info "To restore this backup:  make restore BACKUP=${BACKUP_PATH}"
echo ""
