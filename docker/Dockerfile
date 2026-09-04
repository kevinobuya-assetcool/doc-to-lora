# syntax=docker/dockerfile:1.7
#
# Single shared image for both doc-to-lora jobs (QA generation and hypernetwork
# training) since they use the exact same uv-managed environment. The
# JOB_TYPE env var picked up by entrypoint.sh selects which one runs.
#
# Base: CUDA 13 (cu130) to match torch==2.13.0 as pinned transitively by
# vllm==0.28.0 in pyproject.toml/uv.lock. "devel" (not "runtime") because vLLM's
# flashinfer backend JIT-compiles kernels at startup via ninja/nvcc.
FROM nvidia/cuda:13.0.3-cudnn-devel-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    HF_XET_HIGH_PERFORMANCE=1 \
    PATH=/root/.local/bin:$PATH

WORKDIR /app

# ninja-build: flashinfer (vllm's kernel backend) JIT-compiles at startup and
# needs `ninja` on PATH (see pyproject.toml comment on the `ninja` dependency).
# awscli: used by entrypoint.sh to sync job inputs/outputs/checkpoints to S3.
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates git unzip ninja-build \
    && rm -rf /var/lib/apt/lists/* \
    && curl -LsSf https://astral.sh/uv/install.sh | sh \
    && curl -sSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/awscliv2.zip /tmp/aws

# uv manages its own Python 3.10 (matches `uv venv --python 3.10 --seed` in
# install.sh) rather than relying on Ubuntu 24.04's system Python (3.12).
RUN uv python install 3.10

# Install dependencies before copying source so this (large, slow) layer is
# cached across code-only changes. --no-install-project skips building the
# local `ctx-to-lora` package itself, since src/ isn't copied in yet.
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv venv --python 3.10 --seed && \
    uv sync --frozen --no-install-project

COPY . .

# Now install the local project itself (editable) that source is present.
RUN --mount=type=cache,target=/root/.cache/uv uv sync --frozen

# NOTE: flash-attn has no wheel for torch>=2.10 (see pyproject.toml), so the
# perceiver module (src/ctx_to_lora/modeling/idefics2.py) falls back to the
# Hub-hosted kernels-community/flash-attn2 kernel at import time. We tried to
# warm that kernel into this image at build time and found the Hub repo has
# no prebuilt variant for torch==2.13.0/cu130 (only up to torch212/cu132 as of
# tags v0.0.1/v0.0.2 and branches main/v1/v2) -- get_kernel() raises. This is
# an upstream/app-level gap, not a container issue: any code path that
# actually loads the perceiver with this attn_implementation may fail the
# same way at runtime. Left unresolved here; flagged separately.

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
