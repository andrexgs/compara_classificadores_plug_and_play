#!/usr/bin/env bash
# ==============================================================================
# clfbench - End-to-End Container Smoke Test Runner
# Builds the container image(s), runs 'clfbench doctor', and executes 'pytest'.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

log_info() {
    printf '[run_smoke][INFO] %s\n' "$*"
}

log_error() {
    printf '[run_smoke][ERROR] %s\n' "$*" >&2
}

if ! command -v docker >/dev/null 2>&1; then
    log_error "Docker is not installed or not in PATH. Run './scripts/install_docker.sh' first."
    exit 1
fi

log_info "Ensuring host .env and runtime directories are initialized..."
make setup

VCS_REF="$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
BUILD_DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
export VCS_REF BUILD_DATE

if [[ "${1:-}" == "--cpu" ]] || ! docker info 2>/dev/null | grep -qi nvidia; then
    log_info "Building CPU and test container stages..."
    docker compose --profile cpu --profile test build clfbench-cpu test

    log_info "Running 'clfbench doctor' inside CPU container..."
    docker compose --profile cpu run --rm clfbench-cpu clfbench doctor
else
    log_info "Building GPU and test container stages..."
    docker compose --profile test build clfbench test

    log_info "Running 'clfbench doctor' inside GPU container..."
    docker compose run --rm clfbench clfbench doctor
fi

log_info "Running pytest smoke suite inside test container..."
docker compose --profile test run --rm test

log_info "All container smoke checks passed successfully."
