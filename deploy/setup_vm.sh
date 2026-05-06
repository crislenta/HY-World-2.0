#!/usr/bin/env bash
# setup_vm.sh — one-shot bootstrap for an Ubuntu 22.04 GCE VM with an NVIDIA GPU.
#
# Idempotent. Safe to re-run. Performs:
#   1. NVIDIA driver install via the official Google "install-driver" helper
#      (falls back to Ubuntu's `ubuntu-drivers` if that helper is unavailable).
#   2. Docker CE install (skipped if Docker is already present).
#   3. NVIDIA Container Toolkit install + dockerd reconfigure.
#   4. Build + start the HunyuanWorld 2.0 image via docker compose.
#
# Run this on the GCE VM itself (NOT on your laptop):
#   sudo bash deploy/setup_vm.sh
#
# After it finishes, the Gradio UI is reachable on http://<external-ip>:8081
# (assuming the firewall allows ingress on TCP 8081 — see deploy/README.md).

set -euo pipefail

log() { printf '\n\033[1;32m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo bash $0)."
[[ -f /etc/os-release ]] || die "Cannot detect OS — /etc/os-release missing."

# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || warn "Tested on Ubuntu 22.04; ${PRETTY_NAME:-unknown} may need tweaks."

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# 1. NVIDIA driver
# ---------------------------------------------------------------------------
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    log "NVIDIA driver already present:"
    nvidia-smi | head -n 4
else
    log "Installing NVIDIA driver…"
    apt-get update -y
    apt-get install -y --no-install-recommends pciutils ubuntu-drivers-common curl ca-certificates

    # Preferred path on GCE: Google's helper, which picks a tested driver
    # for the attached GPU SKU (T4, L4, A100, H100, …).
    if curl -fsSL -o /tmp/install-driver.py \
        https://raw.githubusercontent.com/GoogleCloudPlatform/compute-gpu-installation/main/linux/install_gpu_driver.py
    then
        python3 /tmp/install-driver.py || warn "Google helper failed; falling back to ubuntu-drivers."
    fi

    if ! command -v nvidia-smi >/dev/null 2>&1; then
        ubuntu-drivers autoinstall || die "ubuntu-drivers autoinstall failed."
    fi

    if ! nvidia-smi >/dev/null 2>&1; then
        warn "Driver installed but kernel module not loaded — a reboot is required."
        warn "Reboot the VM, then re-run: sudo bash deploy/setup_vm.sh"
        exit 0
    fi
fi

# ---------------------------------------------------------------------------
# 2. Docker CE
# ---------------------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
    log "Docker already installed: $(docker --version)"
else
    log "Installing Docker CE…"
    apt-get update -y
    apt-get install -y --no-install-recommends ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
fi

# ---------------------------------------------------------------------------
# 3. NVIDIA Container Toolkit
# ---------------------------------------------------------------------------
if docker info 2>/dev/null | grep -qi 'Runtimes:.*nvidia'; then
    log "NVIDIA Container Toolkit already configured."
else
    log "Installing NVIDIA Container Toolkit…"
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update -y
    apt-get install -y nvidia-container-toolkit
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
fi

# Smoke test: can a container actually see the GPU?
log "Verifying CUDA access from a container…"
if ! docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi >/dev/null; then
    die "Container could not access the GPU. Check NVIDIA driver / toolkit install."
fi
log "GPU access OK."

# ---------------------------------------------------------------------------
# 4. Build + start the app
# ---------------------------------------------------------------------------
log "Building image (first build downloads PyTorch + deps; takes a while)…"
docker compose -f deploy/docker-compose.yml build

log "Starting hyworld2 container…"
docker compose -f deploy/docker-compose.yml up -d

log "Done. Container status:"
docker compose -f deploy/docker-compose.yml ps

EXTERNAL_IP="$(curl -fsS -H 'Metadata-Flavor: Google' \
    http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip \
    2>/dev/null || true)"

cat <<EOF

==========================================================================
HunyuanWorld 2.0 deploy complete.

The Gradio UI is starting up. Model weights (~tens of GB) are pulled from
HuggingFace on the first request, so the first reconstruction will be slow.

Local URL:    http://localhost:8081
${EXTERNAL_IP:+External URL: http://$EXTERNAL_IP:8081}

Tail logs:    docker compose -f deploy/docker-compose.yml logs -f
Stop:         docker compose -f deploy/docker-compose.yml down
Update code:  git pull && docker compose -f deploy/docker-compose.yml up -d --build

If the external URL is unreachable, open the firewall:
  gcloud compute firewall-rules create allow-hyworld-8081 \\
      --allow=tcp:8081 --target-tags=hyworld --source-ranges=0.0.0.0/0
  gcloud compute instances add-tags <INSTANCE> --zone=<ZONE> --tags=hyworld
==========================================================================
EOF
