#!/usr/bin/env bash
# =============================================================================
# scripts/logs.sh — Stream or display Floci container logs
#
# Usage: ./scripts/logs.sh [--tail N] [--follow]
#   --tail N    Show last N lines (default: 100)
#   --follow    Follow log output (stream continuously)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_DIR="${REPO_ROOT}/floci"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"

if [[ -t 1 ]]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RESET='\033[0m'
else
  RED=''; YELLOW=''; CYAN=''; RESET=''
fi

log_info()  { echo -e "${CYAN}[floci]${RESET} $*"; }
log_warn()  { echo -e "${YELLOW}[floci]${RESET} $*"; }
log_error() { echo -e "${RED}[floci] ERROR:${RESET} $*" >&2; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
TAIL_LINES=100
FOLLOW=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tail)
      shift
      TAIL_LINES="${1:-100}"
      ;;
    --follow|-f)
      FOLLOW=true
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

CONTAINER_NAME="${FLOCI_CONTAINER_NAME:-floci}"
CONTAINER_STATUS=$(docker inspect --format '{{.State.Status}}' \
  "${CONTAINER_NAME}" 2>/dev/null || echo "not_found")

if [[ "${CONTAINER_STATUS}" == "not_found" ]]; then
  log_error "Container '${CONTAINER_NAME}' does not exist. Run 'make up' first."
  exit 1
fi

# ---------------------------------------------------------------------------
# Stream logs
# ---------------------------------------------------------------------------
FOLLOW_FLAG=()
[[ "${FOLLOW}" == true ]] && FOLLOW_FLAG=(--follow)

log_info "Logs for container '${CONTAINER_NAME}' (last ${TAIL_LINES} lines):"
[[ "${FOLLOW}" == true ]] && log_info "Following log output. Press Ctrl+C to stop."
echo ""

docker compose \
  --project-directory "${COMPOSE_DIR}" \
  --file "${COMPOSE_FILE}" \
  logs \
  --tail "${TAIL_LINES}" \
  --timestamps \
  "${FOLLOW_FLAG[@]}" \
  floci
