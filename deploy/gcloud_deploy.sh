#!/usr/bin/env bash
# gcloud_deploy.sh — run this on YOUR LAPTOP to ship the repo to a GCE VM
# and run setup_vm.sh remotely. Assumes:
#   - gcloud CLI is installed and authenticated (`gcloud auth login`)
#   - Either GCP_INSTANCE/GCP_ZONE are exported, or you pass them as args
#   - Your account has compute.instanceAdmin or equivalent on the project
#
# Usage:
#   ./deploy/gcloud_deploy.sh <instance-name> <zone> [project]
#
# Example:
#   ./deploy/gcloud_deploy.sh hyworld-gpu us-central1-a my-project
#
# What it does:
#   1. Tars the working tree (excluding .git, hf_cache, outputs)
#   2. gcloud compute scp the tarball to the VM
#   3. gcloud compute ssh into the VM, untars, and runs setup_vm.sh
#   4. Optionally creates a TCP:8081 firewall rule if missing.

set -euo pipefail

INSTANCE="${1:-${GCP_INSTANCE:-}}"
ZONE="${2:-${GCP_ZONE:-}}"
PROJECT="${3:-${GCP_PROJECT:-}}"

if [[ -z "$INSTANCE" || -z "$ZONE" ]]; then
    cat >&2 <<EOF
Usage: $0 <instance-name> <zone> [project]
   or: GCP_INSTANCE=… GCP_ZONE=… [GCP_PROJECT=…] $0
EOF
    exit 2
fi

PROJECT_FLAG=()
[[ -n "$PROJECT" ]] && PROJECT_FLAG=(--project "$PROJECT")

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "[deploy] instance=$INSTANCE zone=$ZONE ${PROJECT:+project=$PROJECT}"

# ---------------------------------------------------------------------------
# 1. Package the working tree (excluding caches and the git history).
# ---------------------------------------------------------------------------
TARBALL="$(mktemp -t hyworld2.XXXXXX.tar.gz)"
trap 'rm -f "$TARBALL"' EXIT

echo "[deploy] Packaging source → $TARBALL"
tar --exclude='.git' \
    --exclude='deploy/hf_cache' \
    --exclude='deploy/outputs' \
    --exclude='hf_cache' \
    --exclude='inference_output' \
    --exclude='**/__pycache__' \
    -czf "$TARBALL" .

# ---------------------------------------------------------------------------
# 2. Copy to the VM.
# ---------------------------------------------------------------------------
echo "[deploy] Copying source to $INSTANCE…"
gcloud compute scp "${PROJECT_FLAG[@]}" --zone "$ZONE" \
    "$TARBALL" "$INSTANCE:/tmp/hyworld2.tar.gz"

# ---------------------------------------------------------------------------
# 3. Extract and run the bootstrap.
# ---------------------------------------------------------------------------
echo "[deploy] Running setup_vm.sh on $INSTANCE (this can take 15-30 min)…"
gcloud compute ssh "${PROJECT_FLAG[@]}" --zone "$ZONE" "$INSTANCE" --command='
    set -e
    sudo rm -rf /opt/hyworld2
    sudo mkdir -p /opt/hyworld2
    sudo tar -xzf /tmp/hyworld2.tar.gz -C /opt/hyworld2
    sudo chown -R "$USER:$USER" /opt/hyworld2
    cd /opt/hyworld2
    sudo bash deploy/setup_vm.sh
'

# ---------------------------------------------------------------------------
# 4. Open the firewall on TCP:8081 if not already.
# ---------------------------------------------------------------------------
if ! gcloud compute firewall-rules describe allow-hyworld-8081 "${PROJECT_FLAG[@]}" >/dev/null 2>&1; then
    echo "[deploy] Creating firewall rule allow-hyworld-8081 (tcp:8081, tag=hyworld)…"
    gcloud compute firewall-rules create allow-hyworld-8081 \
        "${PROJECT_FLAG[@]}" \
        --allow=tcp:8081 --target-tags=hyworld --source-ranges=0.0.0.0/0 \
        --description="HunyuanWorld 2.0 Gradio UI"
fi

CURRENT_TAGS="$(gcloud compute instances describe "$INSTANCE" \
    "${PROJECT_FLAG[@]}" --zone "$ZONE" --format='value(tags.items)')"
if [[ "$CURRENT_TAGS" != *hyworld* ]]; then
    echo "[deploy] Tagging instance with 'hyworld' so the firewall rule applies…"
    gcloud compute instances add-tags "$INSTANCE" \
        "${PROJECT_FLAG[@]}" --zone "$ZONE" --tags=hyworld
fi

EXTERNAL_IP="$(gcloud compute instances describe "$INSTANCE" \
    "${PROJECT_FLAG[@]}" --zone "$ZONE" \
    --format='value(networkInterfaces[0].accessConfigs[0].natIP)')"

cat <<EOF

[deploy] Done.
[deploy] Gradio UI:  http://${EXTERNAL_IP:-<external-ip>}:8081

Tail logs:
  gcloud compute ssh ${PROJECT:+--project $PROJECT }--zone $ZONE $INSTANCE \\
      --command 'cd /opt/hyworld2 && docker compose -f deploy/docker-compose.yml logs -f'
EOF
