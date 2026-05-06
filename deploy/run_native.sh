#!/usr/bin/env bash
# run_native.sh — bare-metal alternative to the Docker workflow.
#
# Creates a Python 3.10 venv at $VENV (default ./.venv), installs the
# repo into it, and launches the WorldMirror 2.0 Gradio UI on port 8081.
# Use this when you want to run on a host that already has the NVIDIA
# driver installed but you'd rather not deal with Docker / nvidia-toolkit.
#
# Usage:
#   ./deploy/run_native.sh           # foreground
#   ./deploy/run_native.sh --bf16    # with bfloat16
#
# Env vars:
#   VENV=/path/to/venv  (default: $REPO_ROOT/.venv)
#   PORT=8081           (override Gradio port)
#   HOST=0.0.0.0        (override Gradio host)
#   HF_TOKEN=hf_…       (HuggingFace token if required)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

VENV="${VENV:-$REPO_ROOT/.venv}"
PORT="${PORT:-8081}"
HOST="${HOST:-0.0.0.0}"

command -v python3.10 >/dev/null || {
    echo "python3.10 is required (gsplat wheel is cp310). Install it and retry." >&2
    exit 1
}

if [[ ! -x "$VENV/bin/python" ]]; then
    echo "[run_native] Creating venv at $VENV"
    python3.10 -m venv "$VENV"
fi

# shellcheck disable=SC1091
source "$VENV/bin/activate"

python -m pip install --upgrade pip setuptools wheel

# PyTorch 2.4 / cu124 must be installed BEFORE the gsplat wheel resolves.
if ! python -c 'import torch; assert torch.__version__.startswith("2.4")' 2>/dev/null; then
    echo "[run_native] Installing torch 2.4.1 (cu124)"
    pip install --index-url https://download.pytorch.org/whl/cu124 \
        torch==2.4.1 torchvision==0.19.1
fi

echo "[run_native] Installing repo requirements"
pip install -r requirements.txt

if [[ -n "${HF_TOKEN:-}" ]]; then
    export HUGGING_FACE_HUB_TOKEN="$HF_TOKEN"
fi
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

echo "[run_native] Launching Gradio on http://$HOST:$PORT"
exec python -m hyworld2.worldrecon.gradio_app \
    --host "$HOST" --port "$PORT" "$@"
