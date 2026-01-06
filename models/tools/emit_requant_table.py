#!/usr/bin/env python3
import argparse
import json
import math
import os
import re
import struct
from typing import Dict, List, Tuple

import numpy as np


def load_scales(path: str) -> Dict[str, Dict]:
    with open(path, "r") as f:
        j = json.load(f)
    return {lyr["name"]: lyr for lyr in j.get("layers", [])}


def pick_layer(layers: Dict[str, Dict], name: str) -> Dict:
    if name in layers:
        return layers[name]

    # Allow regex match if exact name not found
    regex = re.compile(name)
    matches = [v for k, v in layers.items() if regex.search(k)]
    if len(matches) == 1:
        return matches[0]
    if not matches:
        raise ValueError(f"No layer matches '{name}'")
    raise ValueError(f"Multiple layers match '{name}'. Be more specific.")


def choose_shift(real_scales: np.ndarray) -> int:
    max_scale = float(np.max(real_scales)) if real_scales.size else 0.0
    if max_scale <= 0.0:
        return 0
    if max_scale >= 1.0:
        # Q1.31 cannot represent >= 1.0; keep shift 0 and warn in metadata.
        return 0

    shift = 0
    while (max_scale * (1 << shift)) < 0.5 and shift < 31:
        shift += 1
    while (max_scale * (1 << shift)) >= 1.0 and shift > 0:
        shift -= 1
    return shift


def build_table(
    layer: Dict,
    s_in: float,
    s_out: float,
    shift: int,
) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
    w_scales = layer.get("weight_scale", None)
    if w_scales is None:
        raise ValueError("Layer has no weight_scale in scales.json")

    w_scales = np.array(w_scales, dtype=np.float64)
    if w_scales.size == 1:
        w_scales = np.repeat(w_scales, layer["weight_shape"][0])

    real_scales = (s_in * w_scales) / s_out
    scale_q31 = np.rint(real_scales * (2.0 ** (31 + shift))).astype(np.int64)
    scale_q31 = np.clip(scale_q31, -(2**31), (2**31) - 1).astype(np.int32)

    bias = layer.get("bias", None)
    if bias is None:
        bias = np.zeros_like(scale_q31, dtype=np.int32)
    else:
        bias = np.array(bias, dtype=np.int32)
        if bias.size != scale_q31.size:
            raise ValueError("Bias length does not match output channels")

    return real_scales.astype(np.float64), scale_q31, bias


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Emit requant scale/bias table for a layer."
    )
    ap.add_argument("--scales-json", required=True, help="Path to scales.json")
    ap.add_argument("--layer", required=True, help="Layer name (exact or regex)")
    ap.add_argument(
        "--input-scale", type=float, default=None, help="Input activation scale"
    )
    ap.add_argument(
        "--input-layer", default=None, help="Layer name to take input scale from"
    )
    ap.add_argument(
        "--output-scale",
        type=float,
        default=None,
        help="Output activation scale override",
    )
    ap.add_argument(
        "--shift", type=int, default=None, help="Shift amount override (0-31)"
    )
    ap.add_argument("--out-dir", default=".", help="Output directory")
    args = ap.parse_args()

    layers = load_scales(args.scales_json)
    layer = pick_layer(layers, args.layer)

    if args.input_layer:
        in_layer = pick_layer(layers, args.input_layer)
        s_in = float(in_layer.get("activation_scale", 1.0))
    elif args.input_scale is not None:
        s_in = float(args.input_scale)
    else:
        s_in = 1.0

    s_out = (
        float(args.output_scale)
        if args.output_scale is not None
        else float(layer.get("activation_scale", 1.0))
    )

    if s_in <= 0 or s_out <= 0:
        raise ValueError("Activation scales must be > 0")

    # Determine shift
    w_scales = np.array(layer.get("weight_scale", [1.0]), dtype=np.float64)
    if w_scales.size == 1:
        w_scales = np.repeat(w_scales, layer["weight_shape"][0])
    real_scales_tmp = (s_in * w_scales) / s_out
    shift = args.shift if args.shift is not None else choose_shift(real_scales_tmp)
    if shift < 0 or shift > 31:
        raise ValueError("shift must be in [0,31]")

    real_scales, scale_q31, bias = build_table(layer, s_in, s_out, shift)

    os.makedirs(args.out_dir, exist_ok=True)

    # Emit binary: [scale_q31][bias_int32] little-endian per channel
    base_name = layer["name"].replace("/", "_").replace(".", "_")
    bin_path = os.path.join(args.out_dir, f"{base_name}_requant.bin")
    with open(bin_path, "wb") as fbin:
        for s, b in zip(scale_q31, bias):
            fbin.write(struct.pack("<ii", int(s), int(b)))

    shift_reg = (1 << 6) | (1 << 5) | (shift & 0x1F)
    meta = {
        "layer": layer["name"],
        "type": layer.get("type"),
        "output_channels": int(scale_q31.size),
        "input_scale": s_in,
        "output_scale": s_out,
        "shift": int(shift),
        "shift_reg": int(shift_reg),
        "scale_q31_min": int(scale_q31.min()),
        "scale_q31_max": int(scale_q31.max()),
        "real_scale_min": float(real_scales.min()),
        "real_scale_max": float(real_scales.max()),
        "bin_path": bin_path,
        "notes": [
            "shift_reg encodes SATURATE_EN=1, ROUND_EN=1, SHIFT_AMOUNT=shift",
            "Q1.31 multiplier: real_scale ~= scale_q31 / 2^(31+shift)",
        ],
        "warnings": [],
    }

    if real_scales.max() >= 1.0:
        meta["warnings"].append(
            "real_scale >= 1.0; Q1.31 cannot represent this exactly."
        )
    if args.input_scale is None and args.input_layer is None:
        meta["warnings"].append("input_scale not provided; defaulted to 1.0")

    meta_path = os.path.join(args.out_dir, f"{base_name}_requant.json")
    with open(meta_path, "w") as jf:
        json.dump(meta, jf, indent=2)

    print(f"Wrote {bin_path}")
    print(f"Wrote {meta_path}")


if __name__ == "__main__":
    main()
