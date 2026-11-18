#!/usr/bin/env bash
# =============================================================================
# scripts/stop.sh — Stop the Floci local cloud environment
#
# Usage: ./scripts/stop.sh [--volumes]
#
# By default, the named Docker volume (persistent state) is PRESERVED.
# Pass --volumes to also delete the volume and all stored AWS resource state.
# This is a destructive, irreversible operation and requires confirmation.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_DIR="${REPO_ROOT}/floci"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"

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
# Argument parsing
# ---------------------------------------------------------------------------
DELETE_VOLUMES=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --volumes|-v)
      DELETE_VOLUMES=true
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

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  log_error "Compose file not found: ${COMPOSE_FILE}"
  exit 1
fi

# ---------------------------------------------------------------------------
# Confirm before deleting volumes (destructive, irreversible)
# ---------------------------------------------------------------------------
if [[ "${DELETE_VOLUMES}" == true ]]; then
  echo ""
  log_warn "${BOLD}WARNING: --volumes was passed.${RESET}"
  log_warn "This will DELETE the Docker volume containing all Floci state:"
  log_warn "  • IAM users, roles, policies, and access keys"
  log_warn "  • S3 buckets and objects"
  log_warn "  • DynamoDB tables and items"
  log_warn "  • All other simulated AWS resources"
  echo ""
  log_warn "This action is IRREVERSIBLE. Consider running 'make backup' first."
  echo ""
  read -r -p "Type 'yes' to confirm permanent deletion: " CONFIRM
  if [[ "${CONFIRM}" != "yes" ]]; then
    log_info "Aborted. Volume was not deleted."
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Stop Floci
# ---------------------------------------------------------------------------
log_info "Stopping Floci..."

if [[ "${DELETE_VOLUMES}" == true ]]; then
  docker compose \
    --project-directory "${COMPOSE_DIR}" \
    --file "${COMPOSE_FILE}" \
    down --volumes
  log_warn "Volume deleted. All Floci state has been removed."
else
  docker compose \
    --project-directory "${COMPOSE_DIR}" \
    --file "${COMPOSE_FILE}" \
    down
  log_success "Floci stopped. Persistent state is preserved in the Docker volume."
  log_info "Run 'make up' to restart with the same state."
fi
