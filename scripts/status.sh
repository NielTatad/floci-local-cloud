#!/usr/bin/env bash
# =============================================================================
# scripts/status.sh — Show Floci container and endpoint status
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

HOST_PORT="${FLOCI_HOST_PORT:-4566}"
FLOCI_ENDPOINT="http://localhost:${HOST_PORT}"
CONTAINER_NAME="${FLOCI_CONTAINER_NAME:-floci}"

echo ""
echo -e "${BOLD}════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Floci Local Cloud — Status${RESET}"
echo -e "${BOLD}════════════════════════════════════════${RESET}"
echo ""

# ---------------------------------------------------------------------------
# Docker availability
# ---------------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
  log_error "Docker is not installed or not in PATH."
  exit 1
fi

if ! docker info &>/dev/null; then
  log_error "Docker daemon is not running."
  exit 1
fi

# ---------------------------------------------------------------------------
# Compose project status
# ---------------------------------------------------------------------------
log_info "Docker Compose project:"
docker compose \
  --project-directory "${COMPOSE_DIR}" \
  --file "${COMPOSE_FILE}" \
  ps 2>/dev/null || log_warn "Could not read Compose project status."

echo ""

# ---------------------------------------------------------------------------
# Container health state
# ---------------------------------------------------------------------------
CONTAINER_STATUS=$(docker inspect --format '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo "not_found")
HEALTH_STATUS=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no_healthcheck{{end}}' "${CONTAINER_NAME}" 2>/dev/null || echo "unknown")

if [[ "${CONTAINER_STATUS}" == "not_found" ]]; then
  log_warn "Container '${CONTAINER_NAME}' does not exist. Run 'make up' to start."
elif [[ "${CONTAINER_STATUS}" == "running" ]]; then
  log_success "Container: ${BOLD}running${RESET}"
  if [[ "${HEALTH_STATUS}" == "healthy" ]]; then
    log_success "Health:    ${BOLD}healthy${RESET}"
  elif [[ "${HEALTH_STATUS}" == "starting" ]]; then
    log_warn    "Health:    starting (waiting for /_floci/health)"
  else
    log_warn    "Health:    ${HEALTH_STATUS}"
  fi
else
  log_warn "Container: ${CONTAINER_STATUS}"
fi

echo ""

# ---------------------------------------------------------------------------
# HTTP endpoint reachability
# ---------------------------------------------------------------------------
log_info "Endpoint: ${BOLD}${FLOCI_ENDPOINT}/_floci/health${RESET}"

HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  --max-time 5 \
  "${FLOCI_ENDPOINT}/_floci/health" 2>/dev/null || echo "000")

if [[ "${HTTP_STATUS}" == "200" ]]; then
  log_success "Endpoint reachable — HTTP ${HTTP_STATUS}"
elif [[ "${HTTP_STATUS}" == "000" ]]; then
  log_error "Endpoint unreachable (connection refused or timeout)"
else
  log_warn "Endpoint returned HTTP ${HTTP_STATUS}"
fi

echo ""

# ---------------------------------------------------------------------------
# Volume status
# ---------------------------------------------------------------------------
VOLUME_NAME="${FLOCI_VOLUME_NAME:-floci-data}"
if docker volume inspect "${VOLUME_NAME}" &>/dev/null; then
  VOLUME_PATH=$(docker volume inspect --format '{{.Mountpoint}}' "${VOLUME_NAME}" 2>/dev/null || echo "unknown")
  log_success "Volume '${VOLUME_NAME}': exists (${VOLUME_PATH})"
else
  log_warn "Volume '${VOLUME_NAME}': not found (created on first 'make up')"
fi

echo ""

# ---------------------------------------------------------------------------
# Optional: container resource usage
# ---------------------------------------------------------------------------
if [[ "${CONTAINER_STATUS}" == "running" ]]; then
  log_info "Resource usage (snapshot):"
  docker stats --no-stream --format \
    "  CPU: {{.CPUPerc}}   MEM: {{.MemUsage}}   NET: {{.NetIO}}   BLOCK: {{.BlockIO}}" \
    "${CONTAINER_NAME}" 2>/dev/null || log_warn "Could not read resource stats."
fi

echo ""
