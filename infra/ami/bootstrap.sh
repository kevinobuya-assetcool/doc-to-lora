#!/usr/bin/env bash
# Golden AMI provisioning script for doc-to-lora EC2 job instances.
# Run this once on a base Ubuntu 24.04 instance, then snapshot it as an AMI --
# every job launch just boots this AMI and does `docker pull && docker run`
# (see infra/submit_job.sh), never installing a driver/toolkit per launch.
#
# IMPORTANT -- driver choice: G7e's RTX PRO 6000 Blackwell cards are also sold
# under AWS's "gaming"/"GRID" driver docs, but those are for cloud-gaming
# streaming and virtual-desktop (vGPU) licensing respectively -- irrelevant
# here since each job gets the whole GPU via plain passthrough, no display,
# no multi-tenant partitioning. On bare metal / full passthrough, the
# standard NVIDIA driver works for CUDA compute workloads with no license
# server. This script installs that standard driver from NVIDIA's own apt
# repo (not the AWS gaming/GRID S3 buckets), using the same package
# (`nvidia-driver-open`) and toolkit version this was validated against on a
# local RTX 5090 (sm_120 -- same Blackwell compute capability as the G7e's
# RTX PRO 6000): nvidia-driver-open 610.43.02, nvidia-container-toolkit
# 1.19.1, Ubuntu 24.04. Left unpinned below so apt tracks NVIDIA's latest --
# re-verify with nvidia-smi after any rebuild.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    build-essential dkms linux-headers-"$(uname -r)" ca-certificates curl gnupg unzip

# --- NVIDIA driver, from NVIDIA's CUDA network repo (not AWS's gaming/GRID S3 buckets) ---
curl -fsSL -o /tmp/cuda-keyring.deb \
    https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i /tmp/cuda-keyring.deb
rm -f /tmp/cuda-keyring.deb
sudo apt-get update
sudo apt-get install -y --no-install-recommends nvidia-driver-open

# --- Docker CE ---
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin

# --- NVIDIA Container Toolkit (docker `--gpus` passthrough) ---
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /etc/apt/keyrings/nvidia-container-toolkit.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/etc/apt/keyrings/nvidia-container-toolkit.gpg] https://#g' \
    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
sudo apt-get update
sudo apt-get install -y --no-install-recommends nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# --- AWS CLI v2 (for docker login to ECR + entrypoint.sh's S3 sync) ---
curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
sudo /tmp/aws/install
rm -rf /tmp/awscliv2.zip /tmp/aws

echo
echo "Driver install requires a reboot before nvidia-smi/docker --gpus will work."
echo "After rebooting, validate with:"
echo "  nvidia-smi"
echo "  docker run --rm --gpus all nvidia/cuda:13.0.3-base-ubuntu24.04 nvidia-smi"
echo "Only snapshot the AMI after both of those succeed."
