import argparse
import json
import math
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import numpy as np


def parse_idx_and_name(stem: str) -> Tuple[Optional[int], str]:
    if "_" not in stem:
        return None, stem
    prefix, suffix = stem.split("_", 1)
    try:
        return int(prefix), suffix
    except ValueError:
        return None, stem


def gather_pairs(dump_dir: Path) -> List[Tuple[Path, Path]]:
    pairs = []
    for qdq_path in sorted(dump_dir.glob("*_qdq.npy")):
        base_name = qdq_path.name[: -len("_qdq.npy")] + ".npy"
        base_path = qdq_path.with_name(base_name)
        if base_path.exists():
            pairs.append((base_path, qdq_path))
        else:
            print(f"[warn] Missing FP tensor for {qdq_path.name}; skipping.")
    return pairs


def load_activation_scales(path: Optional[str]) -> Dict[str, float]:
    if not path:
        return {}
    manifest = json.loads(Path(path).read_text())
    mapping: Dict[str, float] = {}
    for layer in manifest.get("layers", []):
        name = layer.get("name")
        scale = layer.get("activation_scale")
        if name is None or scale is None:
            continue
        mapping[name.replace(".", "_")] = float(scale)
    return mapping


def compute_metrics(fp: np.ndarray, qdq: np.ndarray, eps: float, act_scale: Optional[float]) -> Dict[str, float]:
    if fp.shape != qdq.shape:
        raise ValueError(f"Mismatched shapes: {fp.shape} vs {qdq.shape}")
    diff = fp - qdq
    abs_diff = np.abs(diff)
    denom = np.maximum(np.abs(fp), eps)
    rel = abs_diff / denom
    mape = float(rel.mean() * 100.0)

    avg_mag = 0.5 * (np.abs(fp) + np.abs(qdq))
    smape_terms = abs_diff / np.maximum(avg_mag, eps)
    smape = float(smape_terms.mean() * 100.0)

    diff_sq_sum = float(np.sum(diff * diff))
    fp_sq_sum = float(np.sum(fp * fp))
    rel_l2 = float(100.0 * (math.sqrt(diff_sq_sum) / (math.sqrt(fp_sq_sum) + eps)))

    max_step = None
    if act_scale is not None:
        max_step = float(abs_diff.max() / max(act_scale, eps))

    return {
        "mape_pct": mape,
        "smape_pct": smape,
        "rel_l2_pct": rel_l2,
        "mean_abs": float(abs_diff.mean()),
        "rmse": float(math.sqrt(np.mean(diff ** 2))),
        "max_abs": float(abs_diff.max()),
        "numel": int(fp.size),
        "mape_sum": float(rel.sum()),
        "smape_sum": float(smape_terms.sum()),
        "diff_sq_sum": diff_sq_sum,
        "fp_sq_sum": fp_sq_sum,
        "abs_sum": float(abs_diff.sum()),
        "max_step": max_step,
    }


def format_table(rows: List[Dict[str, object]]) -> str:
    if not rows:
        return "No *_qdq.npy files found."
    name_width = max(len(str(r["layer"])) for r in rows)
    header = (
        f"{'Idx':>5}  {'Layer':<{name_width}}  {'MAPE%':>10}  {'sMAPE%':>10}  {'RelL2%':>10}  "
        f"{'MeanAbs':>12}  {'RMSE':>12}  {'MaxAbs':>12}  {'MaxStep':>12}"
    )
    lines = [header, "-" * len(header)]
    for r in rows:
        idx = "" if r["idx"] is None else str(r["idx"])
        max_step = r.get("max_step")
        max_step_str = "" if max_step is None else f"{max_step:12.6g}"
        lines.append(
            f"{idx:>5}  {r['layer']:<{name_width}}  "
            f"{r['mape_pct']:10.4f}  {r['smape_pct']:10.4f}  {r['rel_l2_pct']:10.4f}  "
            f"{r['mean_abs']:12.6g}  {r['rmse']:12.6g}  {r['max_abs']:12.6g}  {max_step_str:>12}"
        )
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        description="Report percentage error between FP tensors and their QDQ counterparts."
    )
    parser.add_argument("--dump-dir", required=True, help="Directory produced by cpu_golden_infer.py.")
    parser.add_argument(
        "--eps",
        type=float,
        default=1e-12,
        help="Stability constant when normalizing by FP magnitudes.",
    )
    parser.add_argument(
        "--scales-json",
        default=None,
        help="Optional scales.json manifest to compute max-step errors.",
    )
    parser.add_argument(
        "--sort",
        choices=["index", "error"],
        default="index",
        help="Sort layers by recorded index or by descending percentage error.",
    )
    parser.add_argument(
        "--save-json",
        default=None,
        help="Optional path to write raw metrics as JSON.",
    )
    args = parser.parse_args()

    dump_dir = Path(args.dump_dir)
    if not dump_dir.is_dir():
        raise SystemExit(f"{dump_dir} is not a directory.")

    pairs = gather_pairs(dump_dir)
    if not pairs:
        raise SystemExit("No *_qdq.npy files located; rerun cpu_golden_infer.py with --scales-json.")

    act_scales = load_activation_scales(args.scales_json)

    rows = []
    total_mape = 0.0
    total_smape = 0.0
    total_elements = 0
    max_abs = 0.0
    max_step_global = None
    sum_diff_sq = 0.0
    sum_fp_sq = 0.0
    for fp_path, qdq_path in pairs:
        fp = np.load(fp_path)
        qdq = np.load(qdq_path)
        idx, layer_name = parse_idx_and_name(fp_path.stem)
        act_scale = act_scales.get(layer_name)
        metrics = compute_metrics(fp, qdq, args.eps, act_scale)
        rows.append(
            {
                "idx": idx,
                "layer": layer_name,
                "mape_pct": metrics["mape_pct"],
                "smape_pct": metrics["smape_pct"],
                "rel_l2_pct": metrics["rel_l2_pct"],
                "mean_abs": metrics["mean_abs"],
                "rmse": metrics["rmse"],
                "max_abs": metrics["max_abs"],
                "max_step": metrics["max_step"],
                "fp_path": str(fp_path),
                "qdq_path": str(qdq_path),
            }
        )
        total_mape += metrics["mape_sum"]
        total_smape += metrics["smape_sum"]
        total_elements += metrics["numel"]
        max_abs = max(max_abs, metrics["max_abs"])
        sum_diff_sq += metrics["diff_sq_sum"]
        sum_fp_sq += metrics["fp_sq_sum"]
        if metrics["max_step"] is not None:
            max_step_global = metrics["max_step"] if max_step_global is None else max(max_step_global, metrics["max_step"])

    if args.sort == "error":
        rows.sort(key=lambda r: r["mape_pct"], reverse=True)
    else:
        rows.sort(key=lambda r: (float("inf") if r["idx"] is None else r["idx"], r["layer"]))

    print(format_table(rows))
    overall_mape = (total_mape / total_elements) * 100.0
    overall_smape = (total_smape / total_elements) * 100.0
    overall_rel_l2 = float(100.0 * (math.sqrt(sum_diff_sq) / (math.sqrt(sum_fp_sq) + args.eps)))
    print(f"\nOverall MAPE: {overall_mape:.4f}%")
    print(f"Overall sMAPE: {overall_smape:.4f}%")
    print(f"Overall relative L2 error: {overall_rel_l2:.4f}%")
    print(f"Worst absolute deviation across layers: {max_abs:.6g}")
    if args.scales_json:
        if max_step_global is None:
            print("No activation scales matched dump filenames; max-step error unavailable.")
        else:
            print(f"Worst max-step error: {max_step_global:.6g} steps")

    if args.save_json:
        out_path = Path(args.save_json)
        payload = {
            "dump_dir": str(dump_dir),
            "eps": args.eps,
            "scales_json": args.scales_json,
            "rows": rows,
            "overall_mape_pct": overall_mape,
            "overall_smape_pct": overall_smape,
            "overall_rel_l2_pct": overall_rel_l2,
            "max_abs_diff": max_abs,
            "max_step_error": max_step_global,
        }
        with open(out_path, "w") as f:
            json.dump(payload, f, indent=2)
        print(f"Saved metrics to {out_path}")


if __name__ == "__main__":
    main()
