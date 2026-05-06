# HunyuanWorld 2.0 / WorldMirror 2.0 — GPU runtime image.
#
# Pinned to CUDA 12.4 + Python 3.10 to match the gsplat wheel that the repo
# requirements.txt references:
#   gsplat-1.5.3+pt24cu124-cp310-cp310-linux_x86_64.whl
#
# The image bundles the model code only. Weights (~tens of GB) are pulled
# at first run from HuggingFace into /root/.cache/huggingface, which should
# be mounted as a volume so they persist across container restarts.

FROM nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    HF_HOME=/root/.cache/huggingface \
    PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

# System deps:
#   python3.10 + venv + dev headers
#   ffmpeg (moviepy / video frame extraction)
#   libgl1, libglib2.0-0, libsm6, libxext6, libxrender1 (opencv, open3d)
#   git, build-essential, cmake (only needed if a wheel is missing for a dep)
#   libgomp1 (onnxruntime)
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3.10 python3.10-venv python3.10-dev python3-pip \
        ffmpeg git build-essential cmake \
        libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 libgomp1 \
        ca-certificates curl wget \
    && rm -rf /var/lib/apt/lists/*

RUN ln -sf /usr/bin/python3.10 /usr/local/bin/python && \
    ln -sf /usr/bin/python3.10 /usr/local/bin/python3 && \
    python -m pip install --upgrade pip setuptools wheel

WORKDIR /app

# Install PyTorch 2.4 + CUDA 12.4 build BEFORE the rest, so the gsplat wheel
# (which has a hard ABI dependency on torch 2.4 / cu124) resolves cleanly.
RUN pip install \
        --index-url https://download.pytorch.org/whl/cu124 \
        torch==2.4.1 torchvision==0.19.1

# Install repo Python deps.
# requirements.txt is copied first to maximise Docker layer cache reuse.
COPY requirements.txt /app/requirements.txt
RUN pip install -r /app/requirements.txt

# Now copy the rest of the repo.
COPY . /app

EXPOSE 8081

# Default: launch the bundled Gradio tester UI on 0.0.0.0:8081.
# Override CMD or pass extra args to enable bf16 / FSDP / multi-GPU.
CMD ["python", "-m", "hyworld2.worldrecon.gradio_app", \
     "--host", "0.0.0.0", "--port", "8081", \
     "--enable_bf16"]
