set -euo pipefail

# Configurable vars:
ENV_NAME=${ENV_NAME:-vit_tiny}
PY_VER=${PY_VER:-3.10}
MODEL_ID=${MODEL_ID:-1wJlS2NA1M7yshRP26ENWwIQse9Zxph-f}
MODEL_FILENAME=${MODEL_FILENAME:-tiny_vit_5m_1k.pth}
SAMPLE_ID=${SAMPLE_ID:-1FC_deFMdJ6VPrDCmxQ9dDu7G8ulPOKOy}
SAMPLE_ZIP_NAME=${SAMPLE_ZIP_NAME:-sample_image.zip}

SCRIPT_DIR=$(cd -- "$(dirname "$0")" && pwd)
REPO_ROOT="$SCRIPT_DIR"
REQ_FILE="$REPO_ROOT/requirements.txt"
CKPT_DIR="$REPO_ROOT/models/checkpoints"
DUMP_DIR="$REPO_ROOT/models/dumps"

command -v conda >/dev/null 2>&1 || { echo "[ERR] conda not found in PATH." >&2; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo "[ERR] unzip not found; install it and re-run." >&2; exit 1; }

CONDA_BASE=$(conda info --base)
# shellcheck source=/dev/null
source "$CONDA_BASE/etc/profile.d/conda.sh"

if conda env list | awk '{print $1}' | grep -Fxq "$ENV_NAME"; then
  echo "[INFO] Conda env '$ENV_NAME' already exists."
else
  echo "[INFO] Creating conda env '$ENV_NAME' (python=$PY_VER)..."
  conda create -y -n "$ENV_NAME" "python=$PY_VER"
fi

conda activate "$ENV_NAME"

echo "[INFO] Upgrading pip and installing requirements..."
python -m pip install --upgrade pip
python -m pip install -r "$REQ_FILE" gdown

if [[ -n "$MODEL_ID" ]]; then
  mkdir -p "$CKPT_DIR"
  echo "[INFO] Downloading model weights to $CKPT_DIR/$MODEL_FILENAME ..."
  gdown --id "$MODEL_ID" -O "$CKPT_DIR/$MODEL_FILENAME"
else
  echo "[WARN] MODEL_ID not set; skipping model download."
fi

if [[ -n "$SAMPLE_ID" ]]; then
  mkdir -p "$DUMP_DIR"
  ZIP_PATH="$DUMP_DIR/$SAMPLE_ZIP_NAME"
  echo "[INFO] Downloading sample images to $ZIP_PATH ..."
  gdown --id "$SAMPLE_ID" -O "$ZIP_PATH"
  echo "[INFO] Unzipping sample images into $DUMP_DIR ..."
  unzip -o "$ZIP_PATH" -d "$DUMP_DIR"
else
  echo "[WARN] SAMPLE_ID not set; skipping sample image download."
fi

echo "[INFO] Done. Activate with: conda activate $ENV_NAME"
