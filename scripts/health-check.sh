#!/usr/bin/env bash
# =============================================================================
# scripts/health-check.sh — Verify Floci is running and fully ready
#
# Exit codes:
#   0 — healthy and ready
#   1 — unhealthy or not running
#
# This script checks both the Docker container state AND the HTTP readiness
# endpoint. A running container alone is not sufficient evidence of readiness.
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
log_success() { echo -e "${GREEN}[✓]${RESET} $*"; }
log_warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
log_error()   { echo -e "${RED}[✗]${RESET} $*" >&2; }

HOST_PORT="${FLOCI_HOST_PORT:-4566}"
FLOCI_ENDPOINT="http://localhost:${HOST_PORT}"
CONTAINER_NAME="${FLOCI_CONTAINER_NAME:-floci}"
OVERALL_HEALTHY=true

echo ""
echo -e "${BOLD}════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Floci Health Check${RESET}"
echo -e "${BOLD}════════════════════════════════════════${RESET}"
echo ""

# ---------------------------------------------------------------------------
# Check 1: Docker daemon reachable
# ---------------------------------------------------------------------------
echo -e "${BOLD}1. Docker daemon${RESET}"
if ! command -v docker &>/dev/null; then
  log_error "Docker not found in PATH."
  OVERALL_HEALTHY=false
elif ! docker info &>/dev/null 2>&1; then
  log_error "Docker daemon is not running."
  OVERALL_HEALTHY=false
else
  log_success "Docker daemon is reachable."
fi
echo ""

# ---------------------------------------------------------------------------
# Check 2: Container exists and is running
# ---------------------------------------------------------------------------
echo -e "${BOLD}2. Container state${RESET}"
CONTAINER_STATUS=$(docker inspect --format '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo "not_found")

if [[ "${CONTAINER_STATUS}" == "not_found" ]]; then
  log_error "Container '${CONTAINER_NAME}' does not exist. Run 'make up'."
  OVERALL_HEALTHY=false
elif [[ "${CONTAINER_STATUS}" == "running" ]]; then
  log_success "Container '${CONTAINER_NAME}' is running."

  # Uptime
  STARTED_AT=$(docker inspect --format '{{.State.StartedAt}}' "${CONTAINER_NAME}" 2>/dev/null || echo "unknown")
  log_info "  Started at: ${STARTED_AT}"

  # Exit code (should be 0 while running)
  EXIT_CODE=$(docker inspect --format '{{.State.ExitCode}}' "${CONTAINER_NAME}" 2>/dev/null || echo "unknown")
  log_info "  Exit code:  ${EXIT_CODE}"
else
  log_error "Container '${CONTAINER_NAME}' is in state: ${CONTAINER_STATUS}"
  OVERALL_HEALTHY=false
fi
echo ""

# ---------------------------------------------------------------------------
# Check 3: Docker health check status
# ---------------------------------------------------------------------------
echo -e "${BOLD}3. Docker health check${RESET}"
HEALTH_STATUS=$(docker inspect --format \
  '{{if .State.Health}}{{.State.Health.Status}}{{else}}no_healthcheck{{end}}' \
  "${CONTAINER_NAME}" 2>/dev/null || echo "unknown")

case "${HEALTH_STATUS}" in
  healthy)
    log_success "Docker health check: healthy"
    ;;
  starting)
    log_warn "Docker health check: still starting — container may not be ready yet."
    OVERALL_HEALTHY=false
    ;;
  unhealthy)
    log_error "Docker health check: unhealthy"
    # Print the last health check log
    LAST_LOG=$(docker inspect --format \
      '{{range .State.Health.Log}}{{.Output}}{{end}}' \
      "${CONTAINER_NAME}" 2>/dev/null | tail -1 || true)
    [[ -n "${LAST_LOG}" ]] && log_error "  Last check output: ${LAST_LOG}"
    OVERALL_HEALTHY=false
    ;;
  no_healthcheck)
    log_warn "No Docker-managed health check configured."
    ;;
  *)
    log_warn "Health check status: ${HEALTH_STATUS}"
    ;;
esac
echo ""

# ---------------------------------------------------------------------------
# Check 4: HTTP endpoint reachability — /_floci/health
# This is the definitive readiness check per Floci documentation.
# A container that is "running" but has not finished startup will return
# a non-200 status or refuse the connection entirely.
# ---------------------------------------------------------------------------
echo -e "${BOLD}4. HTTP readiness — ${FLOCI_ENDPOINT}/_floci/health${RESET}"

HTTP_RESPONSE=$(curl -sf -o /dev/null \
  -w "%{http_code}" \
  --max-time 10 \
  "${FLOCI_ENDPOINT}/_floci/health" 2>/dev/null || echo "000")

if [[ "${HTTP_RESPONSE}" == "200" ]]; then
  log_success "/_floci/health returned HTTP 200 — Floci is ready."
elif [[ "${HTTP_RESPONSE}" == "000" ]]; then
  log_error "Connection refused or timed out on ${FLOCI_ENDPOINT}"
  log_error "  Floci may still be starting. Wait a moment and retry."
  OVERALL_HEALTHY=false
else
  log_error "/_floci/health returned HTTP ${HTTP_RESPONSE} — not ready."
  OVERALL_HEALTHY=false
fi
echo ""

# ---------------------------------------------------------------------------
# Check 5: Named volume exists
# ---------------------------------------------------------------------------
echo -e "${BOLD}5. Persistent volume${RESET}"
VOLUME_NAME="${FLOCI_VOLUME_NAME:-floci-data}"
if docker volume inspect "${VOLUME_NAME}" &>/dev/null; then
  log_success "Volume '${VOLUME_NAME}' exists."
else
  log_warn "Volume '${VOLUME_NAME}' not found (will be created on 'make up')."
fi
echo ""

# ---------------------------------------------------------------------------
# Optional: resource snapshot (only when container is running)
# ---------------------------------------------------------------------------
if [[ "${CONTAINER_STATUS}" == "running" ]]; then
  echo -e "${BOLD}6. Resource snapshot${RESET}"
  docker stats --no-stream --format \
    "  CPU: {{.CPUPerc}}   MEM: {{.MemUsage}} / {{.MemLimit}}   NET I/O: {{.NetIO}}   BLOCK I/O: {{.BlockIO}}" \
    "${CONTAINER_NAME}" 2>/dev/null || log_warn "  Could not read stats."
  echo ""
fi

# ---------------------------------------------------------------------------
# Diagnostic hints when unhealthy
# ---------------------------------------------------------------------------
if [[ "${OVERALL_HEALTHY}" == false ]]; then
  echo -e "${BOLD}Diagnostics${RESET}"
  log_warn "Floci is NOT healthy. Try the following:"
  echo "  make logs        — view container logs"
  echo "  make status      — full container status"
  echo "  make restart     — stop and restart Floci"
  echo "  docker compose --project-directory floci ps   — raw Compose status"
  echo ""
  exit 1
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo -e "${BOLD}════════════════════════════════════════${RESET}"
log_success "${BOLD}All checks passed. Floci is healthy and ready.${RESET}"
echo -e "  Endpoint:    ${BOLD}${FLOCI_ENDPOINT}${RESET}"
echo -e "  Web console: ${BOLD}http://localhost:4500/_floci/ui${RESET} (if enabled)"
echo -e "${BOLD}════════════════════════════════════════${RESET}"
echo ""
