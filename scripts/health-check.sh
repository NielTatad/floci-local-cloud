#!/usr/bin/env bash
# =============================================================================
# scripts/health-check.sh — Verify Floci is running and fully ready
#
# Exit codes:
#   0 — healthy and ready
#   1 — unhealthy or not running
#
# This script checks Docker container state, Docker health status,
# and the Floci HTTP readiness endpoint.
# =============================================================================
set -euo pipefail

if [[ -t 1 ]]; then
  RED='\033[0;31m'
  YELLOW='\033[1;33m'
  GREEN='\033[0;32m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED=''
  YELLOW=''
  GREEN=''
  CYAN=''
  BOLD=''
  RESET=''
fi

log_info()    { echo -e "${CYAN}[floci]${RESET} $*"; }
log_success() { echo -e "${GREEN}[✓]${RESET} $*"; }
log_warn()   { echo -e "${YELLOW}[!]${RESET} $*"; }
log_error()  { echo -e "${RED}[✗]${RESET} $*" >&2; }

HOST_PORT="${FLOCI_HOST_PORT:-4566}"
FLOCI_ENDPOINT="http://localhost:${HOST_PORT}"
CONTAINER_NAME="${FLOCI_CONTAINER_NAME:-floci}"
VOLUME_NAME="${FLOCI_VOLUME_NAME:-floci-data}"

MAX_WAIT="${FLOCI_HEALTH_TIMEOUT:-120}"
INTERVAL=5

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

CONTAINER_STATUS=$(docker inspect \
  --format '{{.State.Status}}' \
  "${CONTAINER_NAME}" 2>/dev/null || echo "not_found")

if [[ "${CONTAINER_STATUS}" == "not_found" ]]; then
  log_error "Container '${CONTAINER_NAME}' does not exist. Run 'make up'."
  OVERALL_HEALTHY=false

elif [[ "${CONTAINER_STATUS}" == "running" ]]; then
  log_success "Container '${CONTAINER_NAME}' is running."

  STARTED_AT=$(docker inspect \
    --format '{{.State.StartedAt}}' \
    "${CONTAINER_NAME}" 2>/dev/null || echo "unknown")

  log_info "  Started at: ${STARTED_AT}"

  EXIT_CODE=$(docker inspect \
    --format '{{.State.ExitCode}}' \
    "${CONTAINER_NAME}" 2>/dev/null || echo "unknown")

  log_info "  Exit code:  ${EXIT_CODE}"

else
  log_error "Container '${CONTAINER_NAME}' is in state: ${CONTAINER_STATUS}"
  OVERALL_HEALTHY=false
fi

echo ""

# ---------------------------------------------------------------------------
# Check 3: Wait for Docker health and HTTP readiness
# ---------------------------------------------------------------------------
echo -e "${BOLD}3. Floci readiness${RESET}"

HEALTH_STATUS="unknown"
HTTP_RESPONSE="000"
READY=false
ELAPSED=0

if [[ "${OVERALL_HEALTHY}" == true ]]; then

  log_info "Waiting up to ${MAX_WAIT}s for Floci to become ready..."

  while (( ELAPSED < MAX_WAIT )); do

    HEALTH_STATUS=$(docker inspect \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no_healthcheck{{end}}' \
      "${CONTAINER_NAME}" 2>/dev/null || echo "unknown")

    HTTP_RESPONSE=$(curl -sS -o /dev/null \
      -w "%{http_code}" \
      --connect-timeout 2 \
      --max-time 5 \
      "${FLOCI_ENDPOINT}/_floci/health" 2>/dev/null || true)

    [[ -n "${HTTP_RESPONSE}" ]] || HTTP_RESPONSE="000"

    if [[ "${HTTP_RESPONSE}" == "200" ]] &&
       [[ "${HEALTH_STATUS}" == "healthy" || "${HEALTH_STATUS}" == "no_healthcheck" ]]; then
      READY=true
      break
    fi

    log_info "Waiting... Docker=${HEALTH_STATUS}, HTTP=${HTTP_RESPONSE} (${ELAPSED}s elapsed)"

    sleep "${INTERVAL}"
    ELAPSED=$((ELAPSED + INTERVAL))
  done

fi

if [[ "${READY}" == true ]]; then
  log_success "Floci is ready."
  log_success "Docker health: ${HEALTH_STATUS}"
  log_success "HTTP readiness: ${HTTP_RESPONSE}"
else
  log_error "Floci did not become ready within ${MAX_WAIT}s."
  log_error "Docker health: ${HEALTH_STATUS}"
  log_error "HTTP response: ${HTTP_RESPONSE}"

  LAST_LOG=$(docker inspect \
    --format '{{range .State.Health.Log}}{{.Output}}{{end}}' \
    "${CONTAINER_NAME}" 2>/dev/null | tail -1 || true)

  [[ -n "${LAST_LOG}" ]] && log_error "Last health check output: ${LAST_LOG}"

  OVERALL_HEALTHY=false
fi

echo ""

# ---------------------------------------------------------------------------
# Check 4: Persistent volume
# ---------------------------------------------------------------------------
echo -e "${BOLD}4. Persistent volume${RESET}"

if docker volume inspect "${VOLUME_NAME}" &>/dev/null; then
  log_success "Volume '${VOLUME_NAME}' exists."
else
  log_warn "Volume '${VOLUME_NAME}' not found (will be created on 'make up')."
fi

echo ""

# ---------------------------------------------------------------------------
# Check 5: Resource snapshot
# ---------------------------------------------------------------------------
if [[ "${CONTAINER_STATUS}" == "running" ]]; then
  echo -e "${BOLD}5. Resource snapshot${RESET}"

  docker stats --no-stream --format \
    "  CPU: {{.CPUPerc}}   MEM: {{.MemUsage}} / {{.MemLimit}}   NET I/O: {{.NetIO}}   BLOCK I/O: {{.BlockIO}}" \
    "${CONTAINER_NAME}" 2>/dev/null || log_warn "Could not read container stats."

  echo ""
fi

# ---------------------------------------------------------------------------
# Diagnostics when unhealthy
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
