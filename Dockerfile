# syntax=docker/dockerfile:1.6
# ==============================================================================
# clfbench Multi-Stage Dockerfile (base, cpu, gpu, dev)
# ==============================================================================

ARG PYTHON_VERSION=3.10
ARG CUDA_VERSION=12.1.1
ARG TORCH_VERSION=2.3.1
ARG TORCHVISION_VERSION=0.18.1
ARG CUDA_WHEEL_TAG=cu121
ARG UID=1000
ARG GID=1000
ARG APP_VERSION=0.1.0
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown

# ------------------------------------------------------------------------------
# Stage 1: base (Ubuntu 22.04 + system dependencies + non-root user)
# ------------------------------------------------------------------------------
FROM ubuntu:22.04 AS base

ARG PYTHON_VERSION
ARG UID
ARG GID
ARG APP_VERSION
ARG VCS_REF
ARG BUILD_DATE

LABEL org.opencontainers.image.title="clfbench" \
      org.opencontainers.image.description="Plug-and-play benchmark framework for PyTorch image classifiers" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    MPLBACKEND=Agg \
    TORCH_HOME=/cache/torch \
    HF_HOME=/cache/huggingface \
    CLFBENCH_GIT_COMMIT=${VCS_REF} \
    PATH="/home/clfbench/.local/bin:${PATH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        build-essential \
        libgl1 \
        libglib2.0-0 \
        fontconfig \
        fonts-dejavu-core \
        python3 \
        python3-dev \
        python3-pip \
        python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python3 /usr/local/bin/python \
    && python -m pip install --upgrade pip setuptools wheel

# Create non-root group/user with configurable UID/GID and runtime directories
RUN groupadd -g "${GID}" -o clfbench \
    && useradd -m -u "${UID}" -g "${GID}" -o -s /bin/bash clfbench \
    && mkdir -p /workspace /data /outputs /cache/torch /cache/huggingface \
    && chown -R "${UID}:${GID}" /workspace /data /outputs /cache

WORKDIR /workspace

# ------------------------------------------------------------------------------
# Stage 2: cpu (Lightweight CPU-only PyTorch runtime)
# ------------------------------------------------------------------------------
FROM base AS cpu

ARG TORCH_VERSION
ARG TORCHVISION_VERSION
ARG UID
ARG GID

# Install CPU-only PyTorch wheels first for optimal layer caching
RUN python -m pip install \
        --index-url https://download.pytorch.org/whl/cpu \
        "torch==${TORCH_VERSION}+cpu" \
        "torchvision==${TORCHVISION_VERSION}+cpu"

# Copy pyproject.toml before source code to maximize Docker layer cache
COPY --chown=${UID}:${GID} pyproject.toml README.md /workspace/
RUN mkdir -p /workspace/src/clfbench \
    && printf '"""Stub package for dependency caching."""\n__version__ = "0.1.0"\n' > /workspace/src/clfbench/__init__.py \
    && python -m pip install . \
    && rm -rf /workspace/src

# Copy full project sources and install package without re-downloading dependencies
COPY --chown=${UID}:${GID} src/ /workspace/src/
COPY --chown=${UID}:${GID} configs/ /workspace/configs/
COPY --chown=${UID}:${GID} tests/ /workspace/tests/
COPY --chown=${UID}:${GID} docker/ /workspace/docker/

RUN chmod +x /workspace/docker/entrypoint.sh \
    && python -m pip install --no-deps -e .

USER ${UID}:${GID}

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD ["python", "/workspace/docker/healthcheck.py"]

ENTRYPOINT ["/workspace/docker/entrypoint.sh"]
CMD ["clfbench", "--help"]

# ------------------------------------------------------------------------------
# Stage 3: gpu (NVIDIA CUDA + cuDNN runtime on Ubuntu 22.04 + PyTorch CUDA)
# ------------------------------------------------------------------------------
FROM nvidia/cuda:${CUDA_VERSION}-cudnn8-runtime-ubuntu22.04 AS gpu

ARG PYTHON_VERSION
ARG TORCH_VERSION
ARG TORCHVISION_VERSION
ARG CUDA_WHEEL_TAG
ARG UID
ARG GID
ARG APP_VERSION
ARG VCS_REF
ARG BUILD_DATE

LABEL org.opencontainers.image.title="clfbench-gpu" \
      org.opencontainers.image.description="Plug-and-play benchmark framework for PyTorch image classifiers (CUDA)" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    MPLBACKEND=Agg \
    TORCH_HOME=/cache/torch \
    HF_HOME=/cache/huggingface \
    CLFBENCH_GIT_COMMIT=${VCS_REF} \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    PATH="/home/clfbench/.local/bin:${PATH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        build-essential \
        libgl1 \
        libglib2.0-0 \
        fontconfig \
        fonts-dejavu-core \
        python3 \
        python3-dev \
        python3-pip \
        python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python3 /usr/local/bin/python \
    && python -m pip install --upgrade pip setuptools wheel

RUN groupadd -g "${GID}" -o clfbench \
    && useradd -m -u "${UID}" -g "${GID}" -o -s /bin/bash clfbench \
    && mkdir -p /workspace /data /outputs /cache/torch /cache/huggingface \
    && chown -R "${UID}:${GID}" /workspace /data /outputs /cache

WORKDIR /workspace

# Install CUDA-enabled PyTorch wheels first for optimal layer caching
RUN python -m pip install \
        --index-url "https://download.pytorch.org/whl/${CUDA_WHEEL_TAG}" \
        "torch==${TORCH_VERSION}" \
        "torchvision==${TORCHVISION_VERSION}"

# Copy pyproject.toml before source code to maximize Docker layer cache
COPY --chown=${UID}:${GID} pyproject.toml README.md /workspace/
RUN mkdir -p /workspace/src/clfbench \
    && printf '"""Stub package for dependency caching."""\n__version__ = "0.1.0"\n' > /workspace/src/clfbench/__init__.py \
    && python -m pip install . \
    && rm -rf /workspace/src

# Copy full project sources and install editable package
COPY --chown=${UID}:${GID} src/ /workspace/src/
COPY --chown=${UID}:${GID} configs/ /workspace/configs/
COPY --chown=${UID}:${GID} tests/ /workspace/tests/
COPY --chown=${UID}:${GID} docker/ /workspace/docker/

RUN chmod +x /workspace/docker/entrypoint.sh \
    && python -m pip install --no-deps -e .

USER ${UID}:${GID}

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD ["python", "/workspace/docker/healthcheck.py"]

ENTRYPOINT ["/workspace/docker/entrypoint.sh"]
CMD ["clfbench", "--help"]

# ------------------------------------------------------------------------------
# Stage 4: dev (Inherits from gpu + [dev] extras + Jupyter + TensorBoard)
# ------------------------------------------------------------------------------
FROM gpu AS dev

ARG UID
ARG GID

USER root

RUN python -m pip install -e ".[dev]" jupyterlab tensorboard

USER ${UID}:${GID}

CMD ["bash"]
