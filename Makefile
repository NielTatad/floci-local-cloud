# =============================================================================
# Floci Local Cloud — Makefile
#
# All commands delegate to the scripts/ directory for logic.
# Run 'make help' to see available targets.
#
# Prerequisites: Docker Engine 23+, Docker Compose v2, GNU Make 3.81+
# =============================================================================

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
# Paths (all relative to this Makefile — do not change)
# ---------------------------------------------------------------------------
REPO_ROOT    := $(shell pwd)
COMPOSE_DIR  := $(REPO_ROOT)/floci
COMPOSE_FILE := $(COMPOSE_DIR)/docker-compose.yml
SCRIPTS_DIR  := $(REPO_ROOT)/scripts
BACKUPS_DIR  := $(REPO_ROOT)/backups

# ---------------------------------------------------------------------------
# Env file — loaded if present; Docker Compose reads it automatically too
# ---------------------------------------------------------------------------
ENV_FILE := $(COMPOSE_DIR)/.env
-include $(ENV_FILE)

# Defaults for variables that may not be set in .env
FLOCI_HOST_PORT      ?= 4566
FLOCI_CONTAINER_NAME ?= floci
FLOCI_VOLUME_NAME    ?= floci-data
BACKUP               ?=

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Cyan/reset are written as literal ANSI codes so they work without tput
CYAN  := \033[0;36m
BOLD  := \033[1m
RESET := \033[0m

define log_info
	@echo -e "$(CYAN)[floci]$(RESET) $(1)"
endef

# Guard: fail fast if Docker is not available
define check_docker
	@if ! command -v docker &>/dev/null; then \
		echo -e "\033[0;31m[floci] ERROR:\033[0m Docker is not installed or not in PATH."; \
		echo "  Install Docker: https://docs.docker.com/get-docker/"; \
		exit 1; \
	fi
	@if ! docker info &>/dev/null; then \
		echo -e "\033[0;31m[floci] ERROR:\033[0m Docker daemon is not running. Start Docker Desktop or the Docker service."; \
		exit 1; \
	fi
	@if ! docker compose version &>/dev/null; then \
		echo -e "\033[0;31m[floci] ERROR:\033[0m Docker Compose v2 plugin is required."; \
		echo "  See: https://docs.docker.com/compose/install/"; \
		exit 1; \
	fi
endef

# Guard: fail if Floci container is not running
define check_running
	@if ! docker inspect --format '{{.State.Status}}' $(FLOCI_CONTAINER_NAME) 2>/dev/null | grep -q '^running$$'; then \
		echo -e "\033[1;33m[floci]\033[0m Floci is not running. Start it first with: make up"; \
		exit 1; \
	fi
endef

# Mark targets that do not correspond to files
.PHONY: up down restart status logs health backup restore clean help

# =============================================================================
# Public targets
# =============================================================================

## up — Start Floci and wait for it to become healthy
up:
	$(call check_docker)
	@bash $(SCRIPTS_DIR)/start.sh

## down — Stop Floci (preserves persistent state volume)
down:
	$(call check_docker)
	@bash $(SCRIPTS_DIR)/stop.sh

## restart — Stop then start Floci
restart: down up

## status — Show container state, endpoint reachability, and volume info
status:
	$(call check_docker)
	@bash $(SCRIPTS_DIR)/status.sh

## logs — Show Floci container logs (last 100 lines)
##        Use ARGS='--follow' to stream: make logs ARGS='--follow'
##        Use ARGS='--tail 50' for fewer lines: make logs ARGS='--tail 50'
logs:
	$(call check_docker)
	@bash $(SCRIPTS_DIR)/logs.sh $(ARGS)

## health — Run the full health check suite (5 checks + diagnostics)
health:
	$(call check_docker)
	@bash $(SCRIPTS_DIR)/health-check.sh

## backup — Back up Floci persistent state to backups/
##          Output: backups/floci-backup-YYYYMMDD-HHMMSS.tar.gz
backup:
	$(call check_docker)
	@bash $(SCRIPTS_DIR)/backup.sh

## restore — Restore Floci state from a backup archive
##           Requires: make restore BACKUP=backups/floci-backup-<timestamp>.tar.gz
##           Floci must be stopped before restoring (make down first).
restore:
	$(call check_docker)
	@if [[ -z "$(BACKUP)" ]]; then \
		echo -e "\033[0;31m[floci] ERROR:\033[0m BACKUP path is required."; \
		echo "  Usage: make restore BACKUP=backups/floci-backup-<timestamp>.tar.gz"; \
		echo ""; \
		echo "  Available backups:"; \
		ls -1t $(BACKUPS_DIR)/*.tar.gz 2>/dev/null | head -10 || echo "    (none found in backups/)"; \
		exit 1; \
	fi
	@bash $(SCRIPTS_DIR)/restore.sh --backup "$(BACKUP)"

## clean — Remove stopped containers and dangling images (SAFE: volume preserved)
##         This does NOT delete the floci-data volume or any persistent state.
##         To also delete the volume: make clean-volumes  (destructive — asks for confirmation)
clean:
	$(call check_docker)
	$(call log_info,"Removing stopped containers and dangling Docker images...")
	@docker compose \
		--project-directory $(COMPOSE_DIR) \
		--file $(COMPOSE_FILE) \
		down --remove-orphans 2>/dev/null || true
	@docker image prune -f --filter "dangling=true" 2>/dev/null || true
	$(call log_info,"Clean complete. Persistent volume '$(FLOCI_VOLUME_NAME)' was NOT deleted.")

## clean-volumes — Remove containers AND the persistent volume (DESTRUCTIVE — requires confirmation)
clean-volumes:
	$(call check_docker)
	@echo ""
	@echo -e "\033[1;33m[floci] WARNING: This will permanently delete the '$(FLOCI_VOLUME_NAME)' volume.\033[0m"
	@echo -e "\033[1;33m[floci] ALL Floci state (IAM, S3, DynamoDB, etc.) will be lost.\033[0m"
	@echo -e "\033[1;33m[floci] Consider running 'make backup' first.\033[0m"
	@echo ""
	@read -r -p "Type 'yes' to confirm permanent deletion: " CONFIRM; \
	if [[ "$$CONFIRM" != "yes" ]]; then \
		echo -e "\033[0;36m[floci]\033[0m Aborted."; \
		exit 0; \
	fi
	@bash $(SCRIPTS_DIR)/stop.sh --volumes
	$(call log_info,"Volume '$(FLOCI_VOLUME_NAME)' has been deleted.")

.PHONY: clean-volumes

# =============================================================================
# Help target — parses ## comments above each target
# =============================================================================

## help — Show this help message
help:
	@echo ""
	@echo -e "$(BOLD)Floci Local Cloud — Available Commands$(RESET)"
	@echo -e "$(CYAN)──────────────────────────────────────────────────────────$(RESET)"
	@grep -E '^##' $(MAKEFILE_LIST) | sed 's/^## //' | \
		awk -F '—' '{ printf "  $(CYAN)make %-20s$(RESET) %s\n", $$1, $$2 }'
	@echo ""
	@echo -e "$(BOLD)Examples$(RESET)"
	@echo "  make up                               Start Floci"
	@echo "  make down                             Stop Floci (state preserved)"
	@echo "  make logs ARGS='--follow'             Stream live logs"
	@echo "  make logs ARGS='--tail 50'            Show last 50 log lines"
	@echo "  make restore BACKUP=backups/floci-backup-20261118-120000.tar.gz"
	@echo ""
	@echo -e "$(BOLD)Endpoint$(RESET)"
	@echo "  AWS-compatible: http://localhost:$(FLOCI_HOST_PORT)"
	@echo "  Web console:    http://localhost:4500/_floci/ui (if enabled)"
	@echo ""
	@echo -e "$(BOLD)AWS CLI (floci profile)$(RESET)"
	@echo "  aws --profile floci --endpoint-url http://localhost:$(FLOCI_HOST_PORT) s3 ls"
	@echo ""
