# Models Toolkit

`models/` hosts everything needed to take the floating-point TinyViT reference through INT8 post-training quantization (PTQ), generate CPU “golden” dumps, and feed the FPGA runtime with consistent artifacts.

## Directory Layout

- `configs/` – YACS configs such as `tiny_vit_5m.yaml`, consumed by `build_model`.
- `checkpoints/` – Full-precision checkpoints (e.g., `tiny_vit_5m_1k.pth`) and exported INT8 blobs, typically under `checkpoints/int8_5m/`.
- `tools/` – Command-line helpers: `ptq_int8_export.py` for PTQ and `cpu_golden_infer.py` for the golden inference pipeline.
- `dumps/` – Scratch assets: calibration samples under `sample_image/` and default golden outputs under `golden/`.
- `Makefile` – Convenience wrapper so both flows run with `make -C models <target>`.

## Workflow At A Glance

1. **Quantize:** Run `make ptq` to calibrate the FP checkpoint and produce `weights.bin + scales.json`.
2. **Verify in software:** Run `make golden` to capture layer-wise NumPy dumps (and optional quantize-dequantize, QDQ, views) for a representative image.
3. **Correlate with hardware:** Use the manifest to DMA the correct weight slices, set per-layer scales, and compare accelerator traces against the CPU dumps.

Keeping these steps synchronized prevents mismatches between software calibration, PS driver programming, and FPGA behavior.

## Post-Training Quantization (`tools/ptq_int8_export.py`)

### Inputs & CLI

| Argument / Var | Purpose |
| -------------- | ------- |
| `--cfg` / `CFG` | TinyViT config (`models/configs/tiny_vit_5m.yaml`). |
| `--ckpt` / `CKPT` | FP checkpoint whose `model` key stores weights. |
| `--calib-dir` / `CALIB_DIR` | ImageFolder root for calibration; default is a small ImageNet subset under `models/dumps/sample_image/train`. |
| `--calib-batches` / `CALIB_BATCHES` | Number of batches observed (coverage vs. runtime). |
| `--batch-size` / `BATCH_SIZE` | Calibration batch size. |
| `--per-channel` / `PER_CHANNEL` | Enable per-output-channel weight scales (recommended; default `1`). |
| `--img-size`, `--num-classes` | Override model shape if deploying a variant. |
| `--out-dir` / `OUT_DIR` | Destination for the exported artifacts (e.g., `models/checkpoints/int8_5m`). |

Invoke directly or via:

```bash
make -C models ptq \
    CFG=models/configs/tiny_vit_5m.yaml \
    CKPT=/data/tiny_vit_5m_1k.pth \
    CALIB_DIR=/datasets/imagenet_subset/train \
    OUT_DIR=models/checkpoints/int8_5m \
    CALIB_BATCHES=100 \
    BATCH_SIZE=32 \
    PER_CHANNEL=1
```

### Calibration Mechanics

- Every `Conv2d`, `Conv2d_BN`, `Linear`, `GELU`, `BatchNorm2d`, and `LayerNorm` registers a `PercentileObserver(p=99.9)`.
- Observers collect absolute activations (NaNs/Infs filtered out) and convert the 99.9th percentile into a symmetric INT8 scale `s = percentile / 127`, which is more robust than max statistics.
- For `Conv2d_BN`, BatchNorm parameters are folded into the convolution weight/bias before quantization so FPGA firmware only handles fused conv nodes.

### Exported Artifacts

1. **`weights.bin`** – INT8 weights for every quantized layer, serialized in `model.named_modules()` order and aligned to 32-byte boundaries for efficient DMA bursts.
2. **`scales.json`** – Human- and machine-readable manifest describing layer names, tensor shapes, byte offsets, activation/weight scales, INT32 bias vectors, and convolution attributes. (See the dedicated section below.)

The script logs `Calib batch i/N` progress and `load_state_dict` status to aid traceability when swapping checkpoints or datasets.

## CPU Golden Inference (`tools/cpu_golden_infer.py`)

### Inputs & CLI

- `--cfg`, `--ckpt`, `--img-size`, `--num-classes` – Mirrors the PTQ setup so the forward graph is identical.
- `--img` / `IMG` – RGB input image; defaults to `models/dumps/sample_image/example.jpg`.
- `--dump-dir` / `DUMP_DIR` – Output directory for NumPy dumps (default `models/dumps/golden`).
- `--scales-json` / `SCALES_JSON` – Optional; if provided, QDQ dumps are emitted alongside floating-point tensors so INT8 behavior can be compared directly.

Example:

```bash
make -C models golden \
    CFG=models/configs/tiny_vit_5m.yaml \
    CKPT=/data/tiny_vit_5m_1k.pth \
    IMG=models/dumps/sample_image/example.jpg \
    IMG_SIZE=224 \
    NUM_CLASSES=1000 \
    DUMP_DIR=models/dumps/golden \
    SCALES_JSON=models/checkpoints/int8_5m/scales.json
```

### What Gets Dumped

- For each `Conv2d`, `Linear`, `GELU`, `BatchNorm2d`, `LayerNorm`, and `Conv2d_BN`, the script saves `####_<module>.npy` in traversal order; indices align with the PTQ manifest, making layer-to-layer comparisons straightforward.
- When `--scales-json` is supplied, `_qdq.npy` companions show the quantized→dequantized tensor using that layer’s activation scale.
- Final head outputs are stored as `logits.npy`, `probs_topk_scores.npy`, and `probs_topk_indices.npy`, providing quick sanity checks on class predictions.

### Hardware Correlation Tips

- Mirror the preprocessing pipeline (resize → center crop → ImageNet mean/std normalize) in PS code so activations seen by hardware match calibration conditions.
- When debugging RTL, compare integer paths first (`_qdq.npy`) so requantization differences surface quickly; fall back to FP dumps when looking for numerical precision errors upstream.
- If many `_qdq.npy` tensors saturate at ±127, expand the calibration set or increase `CALIB_BATCHES` before trusting the exported scales.

## `scales.json` Manifest

`scales.json` teaches PS firmware and FPGA drivers how to interpret `weights.bin`, how to DMA each weight block, and how to program per-layer INT8 requantization. It mirrors TinyViT’s module list (Conv2d_BN, Conv2d, Linear, attention MLP pieces) so software and hardware stay in lock-step.

### Top-Level Fields

- `format` – Version tag used to guard against schema drift.
- `weights_bin` – Relative filename pointing at the packed INT8 tensor blob.
- `preprocess` – Mean/std tuple describing the normalization that produced the activation scales (ImageNet stats for the default 224×224 pipeline).
- `layers` – Ordered array of layer descriptors, matching `model.named_modules()` traversal so you can stream weights in the same sequence as the CPU forward pass.

### Per-Layer Descriptor

- `name` / `type` – Module path and operator kind (e.g., `Conv2d_BN(fused)`, `Linear`) indicating whether BatchNorm is already folded.
- `weight_shape` – Original FP tensor shape (`[out, in, kH, kW]` for convolutions; `[out, in]` for linears) for configuring tilers/GEMMs.
- `weight_offset`, `weight_nbytes` – Byte offset and size of the INT8 weights inside `weights.bin`, enabling precise DMA slicing.
- `weight_scale` – Per-channel or per-tensor scale array, fulfilling `q_w ≈ round(w / s_{w,c})`.
- `activation_scale` – Per-tensor activation scale derived from calibration observers, used with `weight_scale` to recover real values from INT32 accumulators.
- `bias`, `bias_dtype` – INT32 bias values computed as `b_int32 ≈ b / (s_a · s_{w,c})`, so they can be added directly in the integer domain before requantization.
- `stride`, `padding`, `dilation`, `groups` – Only present for convolution-style entries; help PS program layer configuration registers accurately.

### Using Scales On Hardware

- During INT8 compute, the accelerator builds INT32 sums that approximate `y_real ≈ (s_a · s_{w,c}) · y_int32` per output channel `c`.
- Requantization multiplies by `M_c ≈ s_out / (s_a · s_{w,c})` and applies a power-of-two shift to land back in INT8; those multipliers/shifts are programmed directly from `scales.json`.
- Because BatchNorm is folded offline, every conv entry already has fused weights and biases, shrinking the PL pipeline to conv → requant without extra normalization passes.

### Example Snippet

```json
{
  "name": "stages.0.blocks.0.conv1",
  "type": "Conv2d_BN(fused)",
  "weight_shape": [64, 64, 3, 3],
  "weight_offset": 123456,
  "weight_nbytes": 36864,
  "weight_scale": [0.0123, 0.0118, "..."],
  "activation_scale": 0.0215,
  "bias_dtype": "int32",
  "bias": [102, -88, "..."],
  "stride": [1, 1],
  "padding": [1, 1],
  "dilation": [1, 1],
  "groups": 1
}
```

### Sanity Checks When Consuming `scales.json`

1. Ensure `weight_offset` + `weight_nbytes` regions are monotonically increasing and sum to the size of `weights.bin`.
2. Cross-check convolution metadata with your tiler/scheduler tables to avoid off-by-one errors at borders.
3. Confirm the `preprocess` block matches the PS image pipeline; if normalization drifts, activation scales (and therefore requant multipliers) become invalid.
