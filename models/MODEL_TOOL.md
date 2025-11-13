# Models Toolkit

`models/` hosts everything needed to take the floating-point TinyViT reference through INT8 post-training quantization (PTQ), generate CPU “golden” dumps, compare float vs. quantized activations, and feed the FPGA runtime with consistent artifacts.

## Directory Layout

* `configs/` – YACS configs such as `tiny_vit_5m.yaml`, consumed by `build_model`.
* `checkpoints/` – Full-precision checkpoints (e.g., `tiny_vit_5m_1k.pth`) and exported INT8 blobs, typically under `checkpoints/int8_5m/`.
* `tools/` – Command-line helpers:

  * `ptq_int8_export.py` for PTQ export
  * `cpu_golden_infer.py` for the golden inference pipeline
  * `qdq_error_report.py` for post-hoc FP-to-QDQ error analysis
* `dumps/` – Scratch assets: calibration samples under `sample_image/` and default golden outputs under `golden/`.
* `Makefile` – Convenience wrapper so both flows run with `make -C models <target>`.

## Workflow Overview

**Quantize.** Calibrate the FP checkpoint with `ptq_int8_export.py` to produce `weights.bin` + `scales.json`.

**Capture reference dumps.** `cpu_golden_infer.py` records layer-by-layer NumPy tensors (and optional quantize-dequantize, QDQ, views) for representative images.

**Score the quantized path.** `qdq_error_report.py` aggregates relative error metrics between float dumps and their QDQ counterparts so you can isolate sensitive layers before running hardware.

**Correlate with hardware.** Use the manifest to DMA the correct weight slices, set per-layer scales, and compare accelerator traces against the CPU dumps or QDQ metrics.

Keeping these steps synchronized prevents mismatches between software calibration, PS driver programming, and FPGA behavior.

## Post-Training Quantization (`tools/ptq_int8_export.py`)

### Inputs & CLI

| Argument / Var                      | Purpose                                                                                                       |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `--cfg` / `CFG`                     | TinyViT config (`models/configs/tiny_vit_5m.yaml`).                                                           |
| `--ckpt` / `CKPT`                   | FP checkpoint whose `model` key stores weights.                                                               |
| `--calib-dir` / `CALIB_DIR`         | ImageFolder root for calibration; default is a small ImageNet subset under `models/dumps/sample_image/train`. |
| `--calib-batches` / `CALIB_BATCHES` | Number of batches observed (coverage vs. runtime).                                                            |
| `--batch-size` / `BATCH_SIZE`       | Calibration batch size.                                                                                       |
| `--per-channel` / `PER_CHANNEL`     | Enable per-output-channel weight scales (recommended; default `1`).                                           |
| `--img-size`, `--num-classes`       | Override model shape if deploying a variant.                                                                  |
| `--out-dir` / `OUT_DIR`             | Destination for the exported artifacts (e.g., `models/checkpoints/int8_5m`).                                  |

The `make ptq …` target mirrors the CLI flags if you prefer reusable command templates, but the script can also be invoked directly in bespoke automation.

### Calibration Mechanics

Every `Conv2d`, `Conv2d_BN`, `Linear`, `GELU`, `BatchNorm2d`, and `LayerNorm` registers a `PercentileObserver(p=99.9)`.
Observers collect absolute activations (NaNs/Infs filtered out) and convert the 99.9th percentile into a symmetric INT8 scale
  $$
  s_a = \frac{\text{percentile}_{99.9}(|y|)}{127},
  $$
  which is more robust than max-based statistics.
For `Conv2d_BN`, BatchNorm parameters are folded into the convolution weight/bias before quantization so FPGA firmware only handles fused conv nodes.

### Exported Artifacts

**`weights.bin`**
INT8 weights for every quantized layer, serialized in `model.named_modules()` order and aligned to 32-byte boundaries for efficient DMA bursts.

**`scales.json`**
Human- and machine-readable manifest describing layer names, tensor shapes, byte offsets, activation/weight scales, INT32 bias vectors, and convolution attributes (see the dedicated section below).

The script logs `Calib batch i/N` progress and `load_state_dict` status to aid traceability when swapping checkpoints or datasets.

## CPU Golden Inference (`tools/cpu_golden_infer.py`)

### Inputs & CLI

* `--cfg`, `--ckpt`, `--img-size`, `--num-classes` – Mirror the PTQ setup so the forward graph is identical.
* `--img` / `IMG` – RGB input image; defaults to `models/dumps/sample_image/example.jpg`.
* `--dump-dir` / `DUMP_DIR` – Output directory for NumPy dumps (default `models/dumps/golden`).
* `--scales-json` / `SCALES_JSON` – Optional; if provided, QDQ dumps are emitted alongside floating-point tensors so INT8 behavior can be compared directly.

### What Gets Dumped

For each `Conv2d`, `Linear`, `GELU`, `BatchNorm2d`, `LayerNorm`, and `Conv2d_BN`, the script saves
  `####_<module>.npy` in traversal order; indices align with the PTQ manifest, making layer-to-layer comparisons straightforward.
When `--scales-json` is supplied, `_qdq.npy` companions show the quantized→dequantized tensor using that layer’s activation scale. These files feed directly into `qdq_error_report.py`.
Final head outputs are stored as `logits.npy`, `probs_topk_scores.npy`, and `probs_topk_indices.npy`, providing quick sanity checks on class predictions.

## QDQ Error Diagnostics (`tools/qdq_error_report.py`)

`qdq_error_report.py` consumes the FP and `_qdq.npy` activation dumps to quantify how much the quantized path drifts from the floating-point reference. Point the tool at any dump directory produced by `cpu_golden_infer.py` (must include `_qdq.npy` files) and optionally pass the same `scales.json` manifest so per-layer activation scales are available.

### Report Layout

**Tabular output** lists each layer index/name alongside multiple relative metrics and absolute statistics.

**JSON export** (via `--save-json`) mirrors the table for downstream scripting.

**Sorting options** let you keep traversal order (`--sort index`) or bubble up the worst offenders by MAPE (`--sort error`).

### Metric Definitions

All metrics operate in activation units so they stay comparable across layers. Let $y \in \mathbb{R}^n$ denote the floating-point tensor, $y_{\text{qdq}} \in \mathbb{R}^n$ the quantize-dequantize tensor, and $\epsilon > 0$ (default $10^{-12}$) a stability constant to avoid division by zero.

**Mean Absolute Percentage Error (MAPE).**

   $$
   \text{MAPE}(y_{\text{qdq}}, y) = 100 \cdot \operatorname{mean}\!\left(\frac{\lvert y_{\text{qdq}} - y \rvert}{\lvert y \rvert + \epsilon}\right)
   $$

   Highlights average elementwise distortion relative to the true magnitude.

**Symmetric MAPE (sMAPE).**

   $$
   \text{sMAPE}(y_{\text{qdq}}, y) = 100 \cdot \operatorname{mean}\!\left(\frac{\lvert y_{\text{qdq}} - y \rvert}{\frac{\lvert y_{\text{qdq}} \rvert + \lvert y \rvert}{2} + \epsilon}\right)
   $$

   Dampens spikes near zero by scaling against the mean magnitude of both tensors.

**Relative $L_2$ Error.**

   $$
   \text{RelL2}(y_{\text{qdq}}, y) = 100 \cdot \frac{\lVert y_{\text{qdq}} - y \rVert_2}{\lVert y \rVert_2 + \epsilon}
   $$

   Summarizes the energy lost to quantization in a single percentage.

**Max Absolute Error (Steps).**

   $$
   \text{MaxSteps}(y_{\text{qdq}}, y; s_a) = \max_k \frac{\lvert y_{\text{qdq},k} - y_k \rvert}{s_a}
   $$

   where $s_a$ is the activation scale for that layer (from `scales.json`). Values $ \gg 1$ imply multi-step drift relative to the INT8 quantizer’s least significant bit.

Standard absolute metrics (mean, RMSE, max) remain in the report for completeness.

### Operational Guidance

Ensure the naming scheme between dumps and `scales.json` matches (both use `model.named_modules()` with dots replaced by underscores). Otherwise max-step metrics will be omitted.

Use MAPE/sMAPE to spot layers that require tighter calibration, and MaxSteps to judge whether accumulator ranges or requant multipliers need retuning before hardware deployment.
Report summaries (overall MAPE, sMAPE, relative (L_2), worst MaxSteps) provide an immediate sanity check before diving into per-layer detail.

## `scales.json` Manifest

`scales.json` teaches PS firmware and FPGA drivers how to interpret `weights.bin`, how to DMA each weight block, and how to program per-layer INT8 requantization. It mirrors TinyViT’s module list (Conv2d_BN, Conv2d, Linear, attention MLP pieces) so software and hardware stay in lock-step.

### Top-Level Fields

`format` – Version tag used to guard against schema drift.

`weights_bin` – Relative filename pointing at the packed INT8 tensor blob.

`preprocess` – Mean/std tuple describing the normalization that produced the activation scales (ImageNet stats for the default 224×224 pipeline).

`layers` – Ordered array of layer descriptors, matching `model.named_modules()` traversal so you can stream weights in the same sequence as the CPU forward pass.

### Per-Layer Descriptor

`name` / `type` – Module path and operator kind (e.g., `Conv2d_BN(fused)`, `Linear`) indicating whether BatchNorm is already folded.

`weight_shape` – Original FP tensor shape (`[out, in, kH, kW]` for convolutions; `[out, in]` for linears) for configuring tilers/GEMMs.

`weight_offset`, `weight_nbytes` – Byte offset and size of the INT8 weights inside `weights.bin`, enabling precise DMA slicing.

`weight_scale` – Per-channel or per-tensor scale array, following
  $$
  q_w \approx \operatorname{round}!\left(\frac{w}{s_{w,c}}\right).
  $$

`activation_scale` – Per-tensor activation scale (s_a) derived from calibration observers, used together with `weight_scale` to recover real values from INT32 accumulators.

`bias`, `bias_dtype` – INT32 bias values computed as
  $$
  b_{\text{int32}} \approx \frac{b}{s_a \cdot s_{w,c}},
  $$
  so they can be added directly in the integer domain before requantization.

`stride`, `padding`, `dilation`, `groups` – Present for convolution-style entries; help PS program layer configuration registers accurately.

### Using Scales on Hardware

During INT8 compute, the accelerator builds INT32 sums that approximate
  $$
  y_{\text{real},c} \approx (s_a \cdot s_{w,c}) \cdot y_{\text{int32},c}
  $$
  per output channel (c).
Requantization multiplies by
  $$
  M_c \approx \frac{s_{\text{out}}}{s_a \cdot s_{w,c}}
  $$
  and applies a power-of-two shift to land back in INT8; those multipliers/shifts are programmed directly from `scales.json`.

Because BatchNorm is folded offline, every conv entry already has fused weights and biases, shrinking the PL pipeline to `conv → requant` without extra normalization passes.

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

* Ensure `weight_offset` + `weight_nbytes` regions are monotonically increasing and sum to the size of `weights.bin`.
* Cross-check convolution metadata with your tiler/scheduler tables to avoid off-by-one errors at borders.
* Confirm the `preprocess` block matches the PS image pipeline; if normalization drifts, activation scales (and therefore requant multipliers) become invalid.
