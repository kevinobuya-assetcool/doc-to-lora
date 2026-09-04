#!/usr/bin/env bash
# Builds the doc-to-lora job image and pushes it to ECR. Run this once per
# code/dependency change -- job launches should only ever `docker pull`, never
# `uv sync` cold (see infra/README.md for why that matters on billed GPU time).
#
# Usage: AWS_REGION=us-east-1 ECR_REPOSITORY=doc-to-lora ./docker/build_and_push.sh [tag]
set -euo pipefail

AWS_REGION="${AWS_REGION:?set AWS_REGION, e.g. us-east-1 -- must match the region your g7e Fleet and S3 bucket use}"
ECR_REPOSITORY="${ECR_REPOSITORY:?set ECR_REPOSITORY, e.g. doc-to-lora}"
TAG="${1:-$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --short HEAD)}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE_URI="${REGISTRY}/${ECR_REPOSITORY}:${TAG}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

aws ecr describe-repositories --repository-names "$ECR_REPOSITORY" --region "$AWS_REGION" >/dev/null 2>&1 \
    || aws ecr create-repository --repository-name "$ECR_REPOSITORY" --region "$AWS_REGION" >/dev/null

aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$REGISTRY"

docker build -f "$REPO_ROOT/docker/Dockerfile" -t "$IMAGE_URI" "$REPO_ROOT"
docker push "$IMAGE_URI"

echo "Pushed ${IMAGE_URI}"
