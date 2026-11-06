#!/usr/bin/env bash
# ==============================================================================
# clfbench - Idempotent Docker Engine & Compose v2 Installer (Ubuntu/Debian)
# ==============================================================================
set -euo pipefail

log_info() {
    printf '[install_docker][INFO] %s\n' "$*"
}

log_warn() {
    printf '[install_docker][WARN] %s\n' "$*" >&2
}

log_error() {
    printf '[install_docker][ERROR] %s\n' "$*" >&2
}

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log_info "Docker Engine ($(docker --version)) and Docker Compose ($(docker compose version --short)) are already installed. Skipping installation."
else
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS distribution (/etc/os-release missing). Please install Docker manually."
        exit 1
    fi

    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" ]]; then
        log_error "Unsupported distribution '${ID:-unknown}'. This script supports Ubuntu and Debian."
        exit 1
    fi

    SUDO=""
    if [[ "$(id -u)" -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO="sudo"
        else
            log_error "Root privileges or 'sudo' are required to install Docker packages."
            exit 1
        fi
    fi

    log_info "Installing prerequisites for Docker apt repository on ${PRETTY_NAME:-$ID}..."
    ${SUDO} apt-get update -y
    ${SUDO} apt-get install -y ca-certificates curl gnupg

    ${SUDO} install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | ${SUDO} gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        ${SUDO} chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    ARCH="$(dpkg --print-architecture)"
    CODENAME="${VERSION_CODENAME}"
    REPO_LINE="deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${CODENAME} stable"
    echo "${REPO_LINE}" | ${SUDO} tee /etc/apt/sources.list.d/docker.list >/dev/null

    log_info "Installing Docker Engine, CLI, containerd, Buildx, and Compose v2 plugin..."
    ${SUDO} apt-get update -y
    ${SUDO} apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    ${SUDO} systemctl enable --now docker
    log_info "Docker Engine and Compose plugin installed successfully."
fi

TARGET_USER="${SUDO_USER:-$(id -un)}"
if ! id -nG "${TARGET_USER}" 2>/dev/null | grep -qw docker; then
    log_warn "User '${TARGET_USER}' is not yet in the 'docker' group."
    log_info "To run Docker without sudo, execute:"
    printf '\n    sudo usermod -aG docker %s && newgrp docker\n\n' "${TARGET_USER}"
else
    log_info "User '${TARGET_USER}' is already a member of the 'docker' group."
fi
