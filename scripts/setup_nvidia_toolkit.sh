#!/usr/bin/env bash
# ==============================================================================
# clfbench - Idempotent NVIDIA Container Toolkit Installer & Validator
# ==============================================================================
set -euo pipefail

CUDA_TEST_TAG="${CUDA_TEST_TAG:-12.1.1}"
CUDA_TEST_IMAGE="nvidia/cuda:${CUDA_TEST_TAG}-base-ubuntu22.04"

log_info() {
    printf '[setup_nvidia_toolkit][INFO] %s\n' "$*"
}

log_warn() {
    printf '[setup_nvidia_toolkit][WARN] %s\n' "$*" >&2
}

log_error() {
    printf '[setup_nvidia_toolkit][ERROR] %s\n' "$*" >&2
}

if ! command -v nvidia-smi >/dev/null 2>&1; then
    log_error "Host 'nvidia-smi' not found. Install the NVIDIA host GPU driver before running this script."
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    log_error "Docker is not installed. Run './scripts/install_docker.sh' first."
    exit 1
fi

SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        log_error "Root privileges or 'sudo' are required to configure NVIDIA Container Toolkit."
        exit 1
    fi
fi

if command -v nvidia-ctk >/dev/null 2>&1; then
    log_info "nvidia-container-toolkit ($(nvidia-ctk --version 2>/dev/null | head -n 1)) is already installed."
else
    log_info "Adding NVIDIA Container Toolkit apt repository..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | ${SUDO} gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | ${SUDO} tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

    ${SUDO} apt-get update -y
    ${SUDO} apt-get install -y nvidia-container-toolkit
fi

log_info "Configuring Docker runtime via nvidia-ctk..."
${SUDO} nvidia-ctk runtime configure --runtime=docker
${SUDO} systemctl restart docker

log_info "Validating GPU passthrough with '${CUDA_TEST_IMAGE}'..."
docker run --rm --gpus all "${CUDA_TEST_IMAGE}" nvidia-smi
log_info "NVIDIA Container Toolkit validation succeeded."
