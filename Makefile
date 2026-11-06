# ==============================================================================
# clfbench - Project Automation Makefile
# ==============================================================================

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

VENV_DIR ?= .venv
PYTHON ?= python3
CMD ?= clfbench --help
VCS_REF := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_DATE := $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")
HOST_UID := $(shell id -u)
HOST_GID := $(shell id -g)

.PHONY: help setup docker-build docker-build-cpu docker-run docker-shell \
        docker-test doctor tensorboard docker-clean install lint format test

help: ## Show available Makefile targets and descriptions
	@printf "clfbench Makefile Targets:\n"
	@printf "==========================\n"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

setup: ## Create .env with current user UID/GID and initialize data/ and outputs/
	@mkdir -p data outputs
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		sed -i "s/^UID=.*/UID=$(HOST_UID)/" .env; \
		sed -i "s/^GID=.*/GID=$(HOST_GID)/" .env; \
		printf "[setup] Created .env with UID=%s and GID=%s\n" "$(HOST_UID)" "$(HOST_GID)"; \
	else \
		sed -i "s/^UID=.*/UID=$(HOST_UID)/" .env; \
		sed -i "s/^GID=.*/GID=$(HOST_GID)/" .env; \
		printf "[setup] Updated .env with UID=%s and GID=%s\n" "$(HOST_UID)" "$(HOST_GID)"; \
	fi
	@printf "[setup] Verified ./data and ./outputs directories exist.\n"

docker-build: setup ## Build GPU and dev Docker images via Docker Compose
	VCS_REF=$(VCS_REF) BUILD_DATE=$(BUILD_DATE) docker compose build clfbench dev

docker-build-cpu: setup ## Build CPU-only Docker image via Docker Compose
	VCS_REF=$(VCS_REF) BUILD_DATE=$(BUILD_DATE) docker compose --profile cpu build clfbench-cpu

docker-run: ## Run a command inside the clfbench container (usage: make docker-run CMD="clfbench doctor")
	@if docker info 2>/dev/null | grep -qi nvidia; then \
		docker compose run --rm clfbench $(CMD); \
	else \
		docker compose --profile cpu run --rm clfbench-cpu $(CMD); \
	fi

docker-shell: ## Open an interactive bash shell in the dev container with live code mounts
	docker compose --profile dev run --rm dev bash

docker-test: ## Execute pytest with coverage inside the test container
	docker compose --profile test run --rm test

doctor: ## Run clfbench doctor diagnostics (automatically selects GPU or CPU container)
	@if docker info 2>/dev/null | grep -qi nvidia; then \
		docker compose run --rm clfbench clfbench doctor; \
	else \
		docker compose --profile cpu run --rm clfbench-cpu clfbench doctor; \
	fi

tensorboard: ## Launch TensorBoard on port 6006 reading from ./outputs
	docker compose --profile tools up tensorboard

docker-clean: ## Stop containers and remove clfbench images and build orphans
	docker compose --profile cpu --profile dev --profile test --profile tools down --rmi local --remove-orphans

install: ## Create local .venv and install clfbench with [dev] extras natively
	$(PYTHON) -m venv $(VENV_DIR)
	$(VENV_DIR)/bin/pip install --upgrade pip setuptools wheel
	$(VENV_DIR)/bin/pip install -e ".[dev]"

lint: ## Run ruff linter and black format check
	@if [ -x "$(VENV_DIR)/bin/ruff" ]; then \
		$(VENV_DIR)/bin/ruff check src tests docker/healthcheck.py && \
		$(VENV_DIR)/bin/black --check src tests docker/healthcheck.py; \
	else \
		ruff check src tests docker/healthcheck.py && \
		black --check src tests docker/healthcheck.py; \
	fi

format: ## Format Python code with black and ruff --fix
	@if [ -x "$(VENV_DIR)/bin/black" ]; then \
		$(VENV_DIR)/bin/ruff check --fix src tests docker/healthcheck.py && \
		$(VENV_DIR)/bin/black src tests docker/healthcheck.py; \
	else \
		ruff check --fix src tests docker/healthcheck.py && \
		black src tests docker/healthcheck.py; \
	fi

test: ## Run smoke tests locally (uses pytest if available, else unittest)
	@if [ -x "$(VENV_DIR)/bin/pytest" ]; then \
		PYTHONPATH=src $(VENV_DIR)/bin/pytest --cov=clfbench --cov-report=term-missing -v; \
	elif command -v pytest >/dev/null 2>&1; then \
		PYTHONPATH=src pytest --cov=clfbench --cov-report=term-missing -v; \
	else \
		PYTHONPATH=src $(PYTHON) -m unittest discover -s tests -v; \
	fi
