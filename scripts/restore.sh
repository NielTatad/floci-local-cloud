#!/usr/bin/env bash
# =============================================================================
# scripts/restore.sh — Restore Floci state from a backup archive
#
# Usage: ./scripts/restore.sh --backup <path-to-backup.tar.gz>
#
# Safety rules:
#   1. Floci must NOT be running during a restore (this script enforces it).
#   2. The existing volume data is NOT automatically deleted — you must confirm.
#   3. The backup archive is verified before any data is written.
#   4. The original volume is snapshot-renamed before restore, giving you a
#      one-step rollback if anything goes wrong.
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

VOLUME_NAME="${FLOCI_VOLUME_NAME:-floci-data}"
CONTAINER_NAME="${FLOCI_CONTAINER_NAME:-floci}"
BACKUP_FILE=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup|-b)
      shift
      BACKUP_FILE="${1:-}"
      ;;
    *)
      log_warn "Unknown option: $1"
      ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Validate arguments
# ---------------------------------------------------------------------------
if [[ -z "${BACKUP_FILE}" ]]; then
  log_error "No backup file specified."
  echo "Usage: $0 --backup <path-to-backup.tar.gz>"
  echo ""
  echo "Available backups:"
  ls -1t "${REPO_ROOT}/backups/"*.tar.gz 2>/dev/null | head -10 || echo "  (none found in backups/)"
  exit 1
fi

if [[ ! -f "${BACKUP_FILE}" ]]; then
  log_error "Backup file not found: ${BACKUP_FILE}"
  exit 1
fi

# Verify it looks like a valid gzip archive before doing anything destructive
if ! file "${BACKUP_FILE}" 2>/dev/null | grep -qiE 'gzip|compressed'; then
  # 'file' may not be available; fall back to testing with tar
  if ! tar -tzf "${BACKUP_FILE}" &>/dev/null; then
    log_error "Backup file is not a valid gzip archive: ${BACKUP_FILE}"
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Optional: verify SHA-256 checksum if one exists
# ---------------------------------------------------------------------------
CHECKSUM_FILE="${BACKUP_FILE}.sha256"
if [[ -f "${CHECKSUM_FILE}" ]]; then
  log_info "Verifying checksum..."
  if command -v sha256sum &>/dev/null; then
    if sha256sum --check "${CHECKSUM_FILE}" --status; then
      log_success "Checksum verified."
    else
      log_error "Checksum mismatch! The backup archive may be corrupted."
      log_error "Expected: $(cat "${CHECKSUM_FILE}")"
      exit 1
    fi
  elif command -v shasum &>/dev/null; then
    if shasum -a 256 --check "${CHECKSUM_FILE}" --status; then
      log_success "Checksum verified."
    else
      log_error "Checksum mismatch! The backup archive may be corrupted."
      exit 1
    fi
  else
    log_warn "sha256sum / shasum not found — skipping checksum verification."
  fi
else
  log_warn "No checksum file found at ${CHECKSUM_FILE} — skipping integrity check."
fi

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

# Floci MUST be stopped before restoring to avoid data corruption
CONTAINER_STATUS=$(docker inspect --format '{{.State.Status}}' \
  "${CONTAINER_NAME}" 2>/dev/null || echo "not_found")

if [[ "${CONTAINER_STATUS}" == "running" ]]; then
  log_error "Floci is currently running. Stop it before restoring:"
  log_error "  make down"
  exit 1
fi

# ---------------------------------------------------------------------------
# Confirm before overwriting
# ---------------------------------------------------------------------------
BACKUP_BASENAME="$(basename "${BACKUP_FILE}")"
echo ""
log_warn "${BOLD}WARNING: This will overwrite the current Floci state.${RESET}"
log_warn "Volume:  ${VOLUME_NAME}"
log_warn "Backup:  ${BACKUP_BASENAME}"
echo ""

if docker volume inspect "${VOLUME_NAME}" &>/dev/null; then
  log_warn "The existing volume will be RENAMED (not deleted) as a safety snapshot"
  log_warn "before the restore proceeds."
fi

echo ""
read -r -p "Type 'yes' to continue with the restore: " CONFIRM
if [[ "${CONFIRM}" != "yes" ]]; then
  log_info "Restore aborted."
  exit 0
fi

# ---------------------------------------------------------------------------
# Safety snapshot — rename existing volume before touching it
# ---------------------------------------------------------------------------
SAFETY_VOLUME="${VOLUME_NAME}-pre-restore-$(date +%Y%m%d-%H%M%S)"

if docker volume inspect "${VOLUME_NAME}" &>/dev/null; then
  log_info "Creating safety snapshot: '${SAFETY_VOLUME}'"

  # Copy existing volume data into the safety snapshot volume
  docker volume create "${SAFETY_VOLUME}" >/dev/null
  docker run --rm \
    --volume "${VOLUME_NAME}:/source:ro" \
    --volume "${SAFETY_VOLUME}:/dest" \
    alpine:3.21 \
    sh -c "cp -a /source/. /dest/"

  log_success "Safety snapshot created: ${SAFETY_VOLUME}"
  log_info "To roll back: docker volume rm ${VOLUME_NAME} && docker volume create ${VOLUME_NAME}"
  log_info "              Then copy from ${SAFETY_VOLUME} back into ${VOLUME_NAME}"
fi

# ---------------------------------------------------------------------------
# Ensure target volume exists
# ---------------------------------------------------------------------------
if ! docker volume inspect "${VOLUME_NAME}" &>/dev/null; then
  log_info "Creating volume '${VOLUME_NAME}'..."
  docker volume create "${VOLUME_NAME}" >/dev/null
fi

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------
log_info "Restoring ${BACKUP_BASENAME} → volume '${VOLUME_NAME}'..."

# Clear the existing volume contents first, then extract the backup
docker run --rm \
  --volume "${VOLUME_NAME}:/floci-data" \
  --volume "$(realpath "${BACKUP_FILE}"):/backup.tar.gz:ro" \
  alpine:3.21 \
  sh -c "rm -rf /floci-data/* /floci-data/.[!.]* 2>/dev/null || true; tar -xzf /backup.tar.gz -C /floci-data"

log_success "Restore complete."
echo ""
log_info "Start Floci with the restored state: make up"
echo ""
