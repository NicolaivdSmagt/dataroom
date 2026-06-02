#!/bin/bash
# One-shot reproducible setup for Dataroom-as-a-Service on a GCP L4 GPU instance.
# Usage: bash scripts/setup.sh
set -e
cd "$(dirname "$0")/.."

# Single model knob: MODEL=<hf_repo>/<file.gguf>. It drives BOTH the download below and the
# served gguf (docker-compose --model via ${MODEL_FILE}). MODEL_REPO/MODEL_FILE are DERIVED from
# it - set them directly only for an advanced override. Default = Qwen3.6 MTP Q4_K_XL.
MODEL_DEFAULT="unsloth/Qwen3.6-35B-A3B-MTP-GGUF/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"

# --- Preflight: fail fast BEFORE the long install + 22GB download ----------------
# The Jina API key powers the agent's web research (jina search / jina read). It is REQUIRED
# (the local v5-nano embedder does NOT need it). Provide it by editing .env, or inline:
#   JINA_API_KEY=jina_xxx bash scripts/setup.sh
ENV_KEY="${JINA_API_KEY:-}"          # a key passed in the environment (inline), if any

if [ ! -f .env ]; then
  if [ -n "$ENV_KEY" ] && [ "$ENV_KEY" != "jina_xxxx" ]; then
    cp .env.example .env
    sed -i "s|^JINA_API_KEY=.*|JINA_API_KEY=$ENV_KEY|" .env
    echo "Created .env with the JINA_API_KEY from your environment."
  else
    echo "ERROR: no JINA_API_KEY. Either:" >&2
    echo "  cp .env.example .env   and edit JINA_API_KEY,  or" >&2
    echo "  JINA_API_KEY=jina_xxx bash scripts/setup.sh   (free key: https://jina.ai/api-dashboard/)" >&2
    exit 1
  fi
fi

# If .env still holds the placeholder but a key was passed inline, inject it.
JINA_API_KEY="$(grep -E '^JINA_API_KEY=' .env | head -n1 | cut -d= -f2-)"
if { [ -z "$JINA_API_KEY" ] || [ "$JINA_API_KEY" = "jina_xxxx" ]; } \
   && [ -n "$ENV_KEY" ] && [ "$ENV_KEY" != "jina_xxxx" ]; then
  sed -i "s|^JINA_API_KEY=.*|JINA_API_KEY=$ENV_KEY|" .env
  JINA_API_KEY="$ENV_KEY"
fi
if [ -z "$JINA_API_KEY" ] || [ "$JINA_API_KEY" = "jina_xxxx" ]; then
  echo "ERROR: JINA_API_KEY in .env is still the placeholder. Edit .env and set a real key" >&2
  echo "       (free key at https://jina.ai/api-dashboard/), or pass JINA_API_KEY=... inline." >&2
  exit 1
fi

# Backend mode. The DEFAULT is a remote OpenAI-compatible endpoint (LLM_BASE_URL in .env); in
# that mode we skip the GPU preflight and the ~22GB model download entirely. Self-hosting the
# model locally is opt-in: set LLAMA_URL (and leave LLM_BASE_URL unset) in .env, then this script
# downloads the GGUF and you start the GPU container with `docker compose --profile local up -d`.
LLM_BASE_URL="$(grep -E '^LLM_BASE_URL=' .env | head -n1 | cut -d= -f2-)"
LLAMA_URL_ENV="$(grep -E '^LLAMA_URL=' .env | head -n1 | cut -d= -f2-)"
if [ -n "$LLM_BASE_URL" ] || [ -z "$LLAMA_URL_ENV" ]; then
  LOCAL_BACKEND=0
else
  LOCAL_BACKEND=1
fi

if [ "$LOCAL_BACKEND" = "1" ]; then
  # Resolve the single MODEL knob (env > .env > default) and derive repo/file for download + serve.
  MODEL="${MODEL:-$(grep -E '^MODEL=' .env | head -n1 | cut -d= -f2-)}"
  MODEL="${MODEL:-$MODEL_DEFAULT}"
  MODEL_REPO="${MODEL_REPO:-${MODEL%/*}}"     # repo = everything before the last "/"
  MODEL_FILE="${MODEL_FILE:-${MODEL##*/}}"    # file = the trailing ".gguf"
  # Persist the derived filename so docker-compose can interpolate ${MODEL_FILE} for --model.
  if grep -q '^MODEL_FILE=' .env; then
    sed -i "s|^MODEL_FILE=.*|MODEL_FILE=$MODEL_FILE|" .env
  else
    echo "MODEL_FILE=$MODEL_FILE" >> .env
  fi

  # GPU preflight: the llama-server container reserves nvidia GPUs, so a driver is required.
  if ! command -v nvidia-smi &>/dev/null || ! nvidia-smi &>/dev/null; then
    echo "ERROR: nvidia-smi not found or no NVIDIA driver responding. Self-hosting the model" >&2
    echo "       (LLAMA_URL set) needs an NVIDIA GPU + driver. Use a remote LLM_BASE_URL to" >&2
    echo "       run without a GPU." >&2
    exit 1
  fi
else
  echo "=== Remote LLM backend (LLM_BASE_URL set; skipping GPU preflight + model download) ==="
fi

# Disk preflight: ~22GB model + several-GB images + job data. Warn under ~40GB free.
# Only the local backend pulls the ~22GB model; remote mode needs far less.
if [ "$LOCAL_BACKEND" = "1" ]; then
  AVAIL_GB="$(df -P . | awk 'NR==2{print int($4/1024/1024)}')"
  if [ -n "$AVAIL_GB" ] && [ "$AVAIL_GB" -lt 40 ]; then
    echo "WARNING: only ${AVAIL_GB}GB free here; the model (~22GB) + images + job data may not fit." >&2
    echo "         Free space or use a larger disk before continuing." >&2
  fi
fi

# This script supports the documented Debian/Ubuntu image (apt). Bail clearly elsewhere.
if ! command -v apt-get &>/dev/null; then
  echo "ERROR: this script targets Debian/Ubuntu (apt-get). On RHEL/Rocky/AmazonLinux, install" >&2
  echo "       Docker + nvidia-container-toolkit manually, then run: sudo docker compose up -d --build" >&2
  exit 1
fi

echo "=== Installing Docker ==="
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER" || true
fi

echo "=== Installing NVIDIA Container Toolkit ==="
if ! dpkg -l | grep -q nvidia-container-toolkit; then
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
  sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker
fi

mkdir -p models data
if [ "$LOCAL_BACKEND" = "1" ]; then
  echo "=== Downloading model ($MODEL_FILE, ~22GB; this can take many minutes) ==="
  if [ ! -f "models/$MODEL_FILE" ]; then
    # Use uv to fetch huggingface-hub in an ephemeral env (no host-python pollution / no
    # --break-system-packages). hf_hub_download caches + resumes, so a preempted SPOT instance
    # can re-run setup and pick up where it left off. Fall back to pip if uv is unavailable.
    if command -v uv &>/dev/null; then
      uv run --with huggingface-hub python -c "from huggingface_hub import hf_hub_download; \
hf_hub_download('$MODEL_REPO', '$MODEL_FILE', local_dir='models')"
    else
      pip install -q huggingface-hub || pip3 install -q --break-system-packages huggingface-hub
      python3 -c "from huggingface_hub import hf_hub_download; \
hf_hub_download('$MODEL_REPO', '$MODEL_FILE', local_dir='models')"
    fi
  else
    echo "Model already present."
  fi
fi

# Compose profile: the local backend adds the GPU llama-server container; remote mode omits it.
COMPOSE_PROFILE_ARGS=""
if [ "$LOCAL_BACKEND" = "1" ]; then
  COMPOSE_PROFILE_ARGS="--profile local"
fi

# DAAS_PULL=1 -> use the prebuilt app image from GHCR (fast, no local build); else build from source.
if [ "${DAAS_PULL:-}" = "1" ]; then
  echo "=== Pulling prebuilt images + starting services ==="
  sudo docker compose $COMPOSE_PROFILE_ARGS pull
  sudo docker compose $COMPOSE_PROFILE_ARGS up -d
else
  echo "=== Building + starting services ==="
  sudo docker compose $COMPOSE_PROFILE_ARGS up -d --build
fi

if [ "$LOCAL_BACKEND" = "1" ]; then
  echo "=== Waiting for llama-server (loads ~22GB from disk on first run) ==="
  llama_ready=
  for i in $(seq 1 90); do
    if curl -fsS http://localhost:8080/health >/dev/null 2>&1; then echo "llama-server ready"; llama_ready=1; break; fi
    echo "waiting llama... ($i/90)"; sleep 5
  done
  if [ -z "$llama_ready" ]; then
    echo "ERROR: llama-server did not become healthy in 7.5 min. Recent logs:" >&2
    sudo docker compose logs --tail 50 llama-server >&2 || true
    echo "       Inspect with: sudo docker compose logs -f llama-server" >&2
  fi
fi

echo "=== Waiting for DaaS API ==="
api_ready=
for i in $(seq 1 30); do
  if curl -fsS http://localhost:8000/health 2>/dev/null | grep -q '"ok":true'; then echo "DaaS API ready"; api_ready=1; break; fi
  echo "waiting api... ($i/30)"; sleep 3
done
if [ -z "$api_ready" ]; then
  echo "ERROR: DaaS API did not become healthy. Recent logs:" >&2
  sudo docker compose logs --tail 50 daas >&2 || true
  echo "       Inspect with: sudo docker compose logs -f daas" >&2
fi

IP=$(curl -s ifconfig.me || echo localhost)
echo ""
echo "=== Deployment complete ==="
echo "DaaS API:         http://$IP:8000"
if [ "$LOCAL_BACKEND" = "1" ]; then
  echo "llama-server API: http://$IP:8080"
fi
echo ""
echo "Submit a job:"
echo "  curl -s -X POST http://$IP:8000/jobs -H 'content-type: application/json' -d '{\"query\":\"...\"}'"
