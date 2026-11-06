#!/usr/bin/env bash
# ==============================================================================
# clfbench Container Entrypoint
# Validates writable runtime directories (/outputs, /cache), checks GPU
# visibility (warning on CPU fallback), and forwards execution to CMD.
# ==============================================================================
set -euo pipefail

log_info() {
    printf '[entrypoint][INFO] %s\n' "$*" >&2
}

log_warn() {
    printf '[entrypoint][WARN] %s\n' "$*" >&2
}

log_error() {
    printf '[entrypoint][ERROR] %s\n' "$*" >&2
}

OUTPUT_DIR="${CLFBENCH_OUTPUT_DIR:-/outputs}"
CACHE_DIR="${CLFBENCH_CACHE_DIR:-/cache}"

# 1. Verify /outputs exists and is writable by the current UID:GID
if [[ ! -d "${OUTPUT_DIR}" ]]; then
    mkdir -p "${OUTPUT_DIR}" 2>/dev/null || {
        log_error "Directory '${OUTPUT_DIR}' does not exist and could not be created by UID=$(id -u) GID=$(id -g)."
        log_error "Run 'make setup' on the host and ensure UID/GID in .env match your host user."
        exit 1
    }
fi

if [[ ! -w "${OUTPUT_DIR}" ]]; then
    log_error "Directory '${OUTPUT_DIR}' is not writable by current user (UID=$(id -u), GID=$(id -g))."
    log_error "Fix host ownership with: sudo chown -R $(id -u):$(id -g) ./outputs"
    exit 1
fi

# 2. Verify /cache exists and is writable by the current UID:GID
if [[ ! -d "${CACHE_DIR}" ]]; then
    mkdir -p "${CACHE_DIR}" 2>/dev/null || {
        log_error "Directory '${CACHE_DIR}' does not exist and could not be created by UID=$(id -u) GID=$(id -g)."
        exit 1
    }
fi

if [[ ! -w "${CACHE_DIR}" ]]; then
    log_error "Directory '${CACHE_DIR}' is not writable by current user (UID=$(id -u), GID=$(id -g))."
    log_error "Check Docker named volume permissions for torch_cache / hf_cache."
    exit 1
fi

mkdir -p "${TORCH_HOME:-${CACHE_DIR}/torch}" "${HF_HOME:-${CACHE_DIR}/huggingface}" 2>/dev/null || true

# 3. Check GPU visibility (warn without failing when running on CPU)
if [[ "${CLFBENCH_FORCE_CPU:-0}" == "1" ]]; then
    log_warn "CLFBENCH_FORCE_CPU=1 is set; running in CPU-only mode."
elif command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    GPU_COUNT="$(nvidia-smi -L | wc -l | tr -d ' ')"
    log_info "Detected ${GPU_COUNT} NVIDIA GPU(s) available to container."
else
    log_warn "No NVIDIA GPU detected inside container; falling back to CPU execution."
fi

# Default command fallback if none provided
if [[ $# -eq 0 ]]; then
    set -- clfbench --help
fi

exec "$@"
