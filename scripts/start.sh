#!/usr/bin/env bash
# =============================================================================
# scripts/start.sh — Start the Floci local cloud environment
#
# Usage: ./scripts/start.sh [--detach] [--build]
#   --detach   Run in background (default: detached)
#   --no-wait  Skip waiting for the health check
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_DIR="${REPO_ROOT}/floci"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
ENV_FILE="${COMPOSE_DIR}/.env"

# Colour helpers (gracefully disabled in non-TTY environments)
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
WAIT=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-wait) WAIT=false ;;
    *) log_warn "Unknown option: $1" ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
  log_error "Docker is not installed or not in PATH."
  log_error "Install Docker: https://docs.docker.com/get-docker/"
  exit 1
fi

if ! docker info &>/dev/null; then
  log_error "Docker daemon is not running. Start Docker and try again."
  exit 1
fi

if ! docker compose version &>/dev/null; then
  log_error "Docker Compose v2 plugin is required."
  log_error "See: https://docs.docker.com/compose/install/"
  exit 1
fi

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  log_error "Compose file not found: ${COMPOSE_FILE}"
  exit 1
fi

# ---------------------------------------------------------------------------
# Env file — copy from example if missing (never overwrite an existing one)
# ---------------------------------------------------------------------------
if [[ ! -f "${ENV_FILE}" ]]; then
  if [[ -f "${COMPOSE_DIR}/.env.example" ]]; then
    log_warn ".env not found — copying from .env.example"
    cp "${COMPOSE_DIR}/.env.example" "${ENV_FILE}"
    log_info "Review ${ENV_FILE} before continuing."
  else
    log_warn ".env not found and no .env.example available. Using Docker Compose defaults."
  fi
fi

# ---------------------------------------------------------------------------
# Check for port conflicts before starting
# ---------------------------------------------------------------------------
HOST_PORT="${FLOCI_HOST_PORT:-4566}"
if command -v ss &>/dev/null; then
  if ss -tlnp 2>/dev/null | grep -q ":${HOST_PORT} "; then
    log_error "Port ${HOST_PORT} is already in use. Stop the conflicting process or change FLOCI_HOST_PORT in floci/.env."
    exit 1
  fi
elif command -v lsof &>/dev/null; then
  if lsof -iTCP:"${HOST_PORT}" -sTCP:LISTEN -t &>/dev/null; then
    log_error "Port ${HOST_PORT} is already in use."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Start Floci
# ---------------------------------------------------------------------------
log_info "Starting Floci (image: floci/floci:${FLOCI_VERSION:-2.5.0}, port: ${HOST_PORT})..."
docker compose \
  --project-directory "${COMPOSE_DIR}" \
  --file "${COMPOSE_FILE}" \
  up --detach --remove-orphans

log_success "Floci container started."

# ---------------------------------------------------------------------------
# Wait for health check
# ---------------------------------------------------------------------------
if [[ "${WAIT}" == true ]]; then
  log_info "Waiting for Floci to become healthy..."
  FLOCI_ENDPOINT="http://localhost:${HOST_PORT}"
  MAX_ATTEMPTS=24   # 24 × 5 s = 120 s max
  ATTEMPT=0

  while [[ ${ATTEMPT} -lt ${MAX_ATTEMPTS} ]]; do
    ATTEMPT=$(( ATTEMPT + 1 ))

    HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
      "${FLOCI_ENDPOINT}/_floci/health" 2>/dev/null || true)

    if [[ "${HTTP_STATUS}" == "200" ]]; then
      log_success "Floci is healthy and ready at ${BOLD}${FLOCI_ENDPOINT}${RESET}"
      log_info "Web console (if enabled): http://localhost:4500/_floci/ui"
      log_info "Run 'make status' or 'make health' to verify anytime."
      exit 0
    fi

    echo -ne "\r${CYAN}[floci]${RESET} Attempt ${ATTEMPT}/${MAX_ATTEMPTS} — waiting for /_floci/health (HTTP ${HTTP_STATUS:-000})..."
    sleep 5
  done

  echo ""
  log_error "Floci did not become healthy within $(( MAX_ATTEMPTS * 5 )) seconds."
  log_error "Check container logs with: make logs"
  log_error "Container status:"
  docker compose --project-directory "${COMPOSE_DIR}" --file "${COMPOSE_FILE}" ps
  exit 1
fi
