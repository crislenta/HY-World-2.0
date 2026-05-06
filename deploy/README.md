# Deploying HunyuanWorld 2.0 on Google Cloud

This folder contains everything needed to stand up the **WorldMirror 2.0**
Gradio tester UI on a GCE VM. The repo already ships an interactive Gradio
frontend at `hyworld2.worldrecon.gradio_app`, so "deploying the repo" and
"having a UI to test it" are the same step here.

```
deploy/
├── Dockerfile             # CUDA 12.4 + Python 3.10 + repo runtime
├── docker-compose.yml     # GPU-enabled service definition
├── setup_vm.sh            # Run ON the GCE VM — installs everything + starts the app
├── gcloud_deploy.sh       # Run on YOUR LAPTOP — ships the repo to a VM and runs setup_vm.sh
├── run_native.sh          # Bare-metal (no Docker) launcher
├── systemd/
│   └── hyworld.service    # Optional auto-start unit
└── README.md
```

---

## 1. Pick a GCE machine type

WorldMirror 2.0 weights load in roughly 6–10 GB of VRAM at the default
`target_size=952`. Headroom for activations and 3DGS rasterisation pushes
real usage to **~16 GB+** for comfortable multi-frame inference, more if
you crank the resolution or feed long videos.

Recommended SKUs:

| Use-case                | GCE family            | GPU       | Notes                                  |
|-------------------------|-----------------------|-----------|----------------------------------------|
| Smoke test / single image | `g2-standard-8`     | 1× L4 24GB | Cheapest "real" option, fits in default quota for many projects |
| Comfortable interactive | `g2-standard-12`      | 1× L4 24GB | Same GPU, more CPU/RAM for video frame extraction |
| Long videos / FSDP      | `a2-highgpu-1g` or 2g | 1–2× A100 | Required for `--use_fsdp` multi-GPU paths |
| Top performance         | `a3-highgpu-8g`       | 8× H100   | Overkill for the demo; useful for batch jobs |

Boot disk: **at least 200 GB** SSD-pd. The HuggingFace cache + container
image alone use 30–60 GB, and `inference_output/` grows quickly with 3DGS
PLYs.

OS image: **Ubuntu 22.04 LTS** (`ubuntu-os-cloud/ubuntu-2204-lts`). The
bootstrap script targets that distro.

Example create command:

```bash
gcloud compute instances create hyworld-gpu \
    --zone=us-central1-a \
    --machine-type=g2-standard-12 \
    --accelerator=type=nvidia-l4,count=1 \
    --maintenance-policy=TERMINATE \
    --image-family=ubuntu-2204-lts \
    --image-project=ubuntu-os-cloud \
    --boot-disk-size=200GB \
    --boot-disk-type=pd-ssd \
    --tags=hyworld
```

---

## 2. Two ways to deploy

### Option A — One-shot from your laptop (recommended)

Requires `gcloud` CLI authenticated to the project that owns the VM:

```bash
# From the repo root on your laptop:
./deploy/gcloud_deploy.sh hyworld-gpu us-central1-a my-project
```

The script:

1. Tarballs the repo (excluding `.git`, `hf_cache`, `inference_output`).
2. `gcloud compute scp`s it to `/tmp/hyworld2.tar.gz` on the VM.
3. SSHes in and runs `deploy/setup_vm.sh` as root.
4. Creates the firewall rule `allow-hyworld-8081` and tags the instance
   with `hyworld` so the rule applies.
5. Prints the public URL.

Re-running it is the upgrade path: it copies the latest source and
`docker compose up -d --build` picks up the changes.

### Option B — Run the bootstrap on the VM directly

```bash
# Copy the repo onto the VM however you like (gcloud scp, git clone, …):
gcloud compute scp --recurse . hyworld-gpu:/opt/hyworld2 --zone=us-central1-a

# SSH in and bootstrap:
gcloud compute ssh hyworld-gpu --zone=us-central1-a
sudo bash /opt/hyworld2/deploy/setup_vm.sh
```

`setup_vm.sh` is idempotent. If it ends with the message
*"a reboot is required"*, reboot the VM and re-run it.

---

## 3. Open the firewall

If you used **Option A**, this is already done. Otherwise:

```bash
gcloud compute firewall-rules create allow-hyworld-8081 \
    --allow=tcp:8081 --target-tags=hyworld --source-ranges=0.0.0.0/0
gcloud compute instances add-tags hyworld-gpu --zone=us-central1-a --tags=hyworld
```

For anything other than a quick demo, restrict `--source-ranges` to your
own IP and put a reverse proxy (nginx + Let's Encrypt, or IAP TCP
forwarding) in front. Gradio has no built-in auth.

---

## 4. Use the UI

Open `http://<external-ip>:8081`. The Gradio app exposes:

- Drag-and-drop image / video upload
- A reconstruct button that runs WorldMirror 2.0 on the inputs
- 3D viewers for the resulting Gaussian Splat and point cloud
- Per-view depth / normal map browsing
- Camera-parameter download
- Pre-loaded example scenes from `examples/worldrecon/`

The **first** reconstruction is slow because the model weights
(~tens of GB) are pulled from HuggingFace into `deploy/hf_cache/` on
the VM. Subsequent runs reuse the cache.

If the model repo on HuggingFace requires accepting a license, set
`HF_TOKEN` before bringing the container up:

```bash
echo "HF_TOKEN=hf_xxxxx" | sudo tee /opt/hyworld2/.env
sudo docker compose -f /opt/hyworld2/deploy/docker-compose.yml up -d
```

---

## 5. Operations cheatsheet

```bash
cd /opt/hyworld2

# Logs (Ctrl-C to detach)
docker compose -f deploy/docker-compose.yml logs -f

# Restart
docker compose -f deploy/docker-compose.yml restart

# Stop
docker compose -f deploy/docker-compose.yml down

# Rebuild after code change
git pull && docker compose -f deploy/docker-compose.yml up -d --build

# Enable bf16 / FSDP (edit the CMD in deploy/Dockerfile or override in compose)
#   --enable_bf16
#   --use_fsdp           (multi-GPU only; launch via torchrun, not the default CMD)
```

To start the app on boot:

```bash
sudo cp /opt/hyworld2/deploy/systemd/hyworld.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now hyworld.service
```

---

## 6. Bare-metal alternative (no Docker)

If your VM already has the NVIDIA driver and you'd rather skip the
container layer:

```bash
sudo apt-get install -y python3.10 python3.10-venv ffmpeg \
    libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 libgomp1
./deploy/run_native.sh
```

This creates `./.venv`, installs torch 2.4 / cu124, the repo
requirements, and launches the same Gradio UI on `0.0.0.0:8081`.

---

## 7. Troubleshooting

| Symptom                                                  | Likely cause / fix                                                               |
|----------------------------------------------------------|----------------------------------------------------------------------------------|
| `nvidia-smi` works but `docker run --gpus all` fails     | NVIDIA Container Toolkit not configured. Re-run `setup_vm.sh`.                   |
| Container exits with `CUDA error: no kernel image`       | Driver too old for CUDA 12.4. Install driver `550+`.                             |
| `gsplat` fails to import                                 | Wrong Python (must be 3.10) or wrong torch (must be 2.4 / cu124). Rebuild image. |
| Browser shows "connection refused"                       | Firewall rule missing or instance lacks the `hyworld` tag.                       |
| First request hangs for many minutes                     | Initial weight download from HuggingFace; tail logs to confirm.                  |
| OOM during reconstruction                                | Lower `target_size` in the Gradio sidebar, or move to a 24 GB+ GPU.              |
