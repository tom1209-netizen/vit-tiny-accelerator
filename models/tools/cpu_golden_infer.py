import argparse, os, json, sys, copy, warnings
from collections import OrderedDict
import torch
import torch.nn as nn
import numpy as np
from types import SimpleNamespace
from pathlib import Path

# Suppress QAT warnings
warnings.filterwarnings("ignore", category=UserWarning)
warnings.filterwarnings("ignore", category=DeprecationWarning)

# Ensure project root (parent of `models`) is on sys.path when running as a script
PROJECT_ROOT = Path(__file__).resolve().parents[2]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from models.core import build_model
from models.common.config import get_config
from models.core.tiny_vit import Conv2d_BN

# QAT imports
from torch.ao.quantization import get_default_qat_qconfig, QConfigMapping
from torch.ao.quantization.quantize_fx import prepare_qat_fx, convert_fx

import torchvision.transforms as T
import torchvision.datasets as dsets
from torch.utils.data import DataLoader
from PIL import Image

IMAGENET_MEAN = [0.485, 0.456, 0.406]
IMAGENET_STD = [0.229, 0.224, 0.225]


def mk_transform(img_size: int):
    return T.Compose(
        [
            T.Resize(256, interpolation=T.InterpolationMode.BICUBIC),
            T.CenterCrop(img_size),
            T.ToTensor(),
            T.Normalize(IMAGENET_MEAN, IMAGENET_STD),
        ]
    )


def is_qat_checkpoint(ckpt_path: str) -> bool:
    """Check if checkpoint is a QAT checkpoint by looking for fake_quant keys."""
    ckpt = torch.load(ckpt_path, map_location="cpu", weights_only=False)
    state = ckpt.get("model", ckpt)
    return any("weight_fake_quant" in k for k in state.keys())


def load_qat_model(float_model: nn.Module, ckpt_path: str, img_size: int = 224):
    """
    Load QAT checkpoint into a prepare_qat_fx wrapped model.
    QAT checkpoints require the FX graph wrapper to function correctly.
    Returns: (qat_model, int8_model, load_msg)
        - qat_model: FP32-equivalent model for FP32 accuracy measurement
        - int8_model: Converted INT8 model for INT8 accuracy measurement
    """
    print(">> [Loader] Detected QAT checkpoint. Using prepare_qat_fx wrapper...")

    # Prepare QAT FX model (same as during training)
    example_inputs = (torch.randn(1, 3, img_size, img_size),)
    qconfig = get_default_qat_qconfig("fbgemm")
    qconfig_mapping = QConfigMapping().set_global(qconfig)
    prepared = prepare_qat_fx(
        copy.deepcopy(float_model), qconfig_mapping, example_inputs
    )

    # Load checkpoint directly into the prepared model
    ckpt = torch.load(ckpt_path, map_location="cpu", weights_only=False)
    state = ckpt.get("model", ckpt)
    msg = prepared.load_state_dict(state, strict=False)

    # Convert to actual INT8 model for INT8 evaluation
    int8_model = convert_fx(copy.deepcopy(prepared.cpu()))

    return prepared, int8_model, str(msg)


def safe_load_checkpoint(model: nn.Module, ckpt_path: str):
    """Load non-QAT (FP32) checkpoint into model."""
    ckpt = torch.load(ckpt_path, map_location="cpu", weights_only=False)
    state = ckpt.get("model", ckpt)
    msg = model.load_state_dict(state, strict=False)
    return str(msg)


def load_scales(path):
    """
    Load scales.json produced by ptq_int8_export.py and return:
      name -> {'act': activation_scale, 'w_scales': [...], 'type': 'Conv2d_BN(fused)' / 'Conv2d' / 'Linear'}
    """
    if path is None:
        return None
    with open(path, "r") as f:
        j = json.load(f)

    name_to = {}
    for lyr in j.get("layers", []):
        name = lyr["name"]
        act_s = float(lyr.get("activation_scale", 1.0))
        w_scales = lyr.get("weight_scale", None)
        ltype = lyr.get("type", None)
        name_to[name] = dict(
            act=act_s,
            w_scales=w_scales,
            type=ltype,
        )
    return name_to


def qdq(x: torch.Tensor, s: float) -> torch.Tensor:
    """
    Symmetric int8 fake-quant: clamp(round(x / s), -128, 127) * s
    """
    if s is None or s <= 0:
        return x
    q = torch.clamp((x / s).round(), -128, 127)
    return q * s


def register_dumps(model: nn.Module, out_dir: str, quant_scales=None):
    """
    Attach forward hooks that:
      - save FP outputs as {idx}_{layer}.npy
      - optionally save QDQ outputs as {idx}_{layer}_qdq.npy (for error report)
    This does NOT change the forward path; it is only for dumping.
    """
    os.makedirs(out_dir, exist_ok=True)
    handles = []
    counter = {"i": 0}

    def hook_maker(name: str):
        def h(_m, _in, out):
            y = out[0] if isinstance(out, tuple) else out
            if not torch.is_tensor(y):
                return
            idx = counter["i"]
            counter["i"] += 1
            ycpu = y.detach().cpu().float()
            base_name = f'{idx:04d}_{name.replace(".", "_")}'
            np.save(os.path.join(out_dir, base_name + ".npy"), ycpu.numpy())

            # optional quantized view via activation scale
            if quant_scales is not None and name in quant_scales:
                s = quant_scales[name]["act"]
                yq = qdq(ycpu, s)
                np.save(os.path.join(out_dir, base_name + "_qdq.npy"), yq.numpy())

        return h

    for n, m in model.named_modules():
        if isinstance(
            m, (nn.Conv2d, nn.Linear, nn.GELU, nn.BatchNorm2d, nn.LayerNorm, Conv2d_BN)
        ):
            handles.append(m.register_forward_hook(hook_maker(n)))

    return handles


def attach_qdq_hooks(model: nn.Module, quant_scales):
    handles = []
    if quant_scales is None:
        return handles

    def hook_maker(name: str):
        def h(_m, _in, out):
            y = out[0] if isinstance(out, tuple) else out
            if not torch.is_tensor(y):
                return out
            if name not in quant_scales:
                return out
            s = quant_scales[name]["act"]
            return qdq(y, s)

        return h

    for n, m in model.named_modules():
        if isinstance(m, (Conv2d_BN, nn.Linear)) and n in quant_scales:
            handles.append(m.register_forward_hook(hook_maker(n)))

    return handles


def accuracy(output, target, topk=(1, 5)):
    """
    Compute top-k accuracy for each k in topk.
    """
    maxk = max(topk)
    batch_size = target.size(0)

    _, pred = output.topk(maxk, 1, True, True)
    pred = pred.t()
    correct = pred.eq(target.view(1, -1).expand_as(pred))

    res = []
    for k in topk:
        correct_k = correct[:k].reshape(-1).float().sum(0, keepdim=True)
        res.append(correct_k.mul_(100.0 / batch_size))
    return res


def evaluate(model: nn.Module, loader: DataLoader):
    """
    Run evaluation over a dataset loader and return (top1, top5) in %.
    """
    model.eval()
    top1_sum, top5_sum, n = 0.0, 0.0, 0
    with torch.no_grad():
        for x, y in loader:
            # Removed erroneous 's' argument here
            logits = model(x)
            acc1, acc5 = accuracy(logits, y)
            bs = x.size(0)
            top1_sum += acc1.item() * bs
            top5_sum += acc5.item() * bs
            n += bs
    if n == 0:
        return 0.0, 0.0
    return top1_sum / n, top5_sum / n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cfg", required=True)
    ap.add_argument("--ckpt", required=True)

    # Single-image dump mode
    ap.add_argument(
        "--img", default=None, help="Optional: single image path for feature dumps"
    )
    ap.add_argument(
        "--dump-dir",
        default=None,
        help="Optional: dump directory for single-image activations",
    )

    ap.add_argument("--img-size", type=int, default=224)
    ap.add_argument("--num-classes", type=int, default=1000)

    # Dataset evaluation mode
    ap.add_argument(
        "--val-dir",
        default=None,
        help="Optional: ImageFolder root for validation evaluation",
    )
    ap.add_argument("--batch-size", type=int, default=64)

    # Scales for QDQ
    ap.add_argument(
        "--scales-json",
        default=None,
        help="Optional: scales.json to enable *_qdq dumps and INT8 eval",
    )

    args = ap.parse_args()

    # Build model/cfg and load weights
    args_ns = SimpleNamespace(
        cfg=args.cfg,
        opts=None,
        batch_size=None,
        data_path=None,
        pretrained=None,
        resume=None,
        accumulation_steps=None,
        use_checkpoint=False,
        disable_amp=True,
        only_cpu=True,
        output="output",
        tag="infer",
        eval=True,
        throughput=False,
        local_rank=0,
    )

    cfg = get_config(args_ns)
    cfg.defrost()
    cfg.DATA.IMG_SIZE = args.img_size
    cfg.MODEL.NUM_CLASSES = args.num_classes
    cfg.AMP_ENABLE = False
    cfg.freeze()

    float_model = build_model(cfg)
    int8_model = None  # Will be set for QAT checkpoints

    # Check if QAT checkpoint and load appropriately
    if is_qat_checkpoint(args.ckpt):
        model, int8_model, load_msg = load_qat_model(
            float_model, args.ckpt, args.img_size
        )
    else:
        model = float_model
        load_msg = safe_load_checkpoint(model, args.ckpt)

    model.eval()
    if int8_model is not None:
        int8_model.eval()
    print(load_msg)

    # Load activation scales
    qscales = load_scales(args.scales_json)

    # Dataset evaluation (FP32 vs INT8 QDQ)
    if args.val_dir is not None:
        print(f"Running dataset evaluation on {args.val_dir}")
        tfm = mk_transform(args.img_size)
        val_ds = dsets.ImageFolder(args.val_dir, transform=tfm)
        val_loader = DataLoader(
            val_ds,
            batch_size=args.batch_size,
            shuffle=False,
            num_workers=8,
            pin_memory=False,
        )

        # FP32
        top1_fp, top5_fp = evaluate(model, val_loader)
        print(f"FP32:   top1 = {top1_fp:.3f}%, top5 = {top5_fp:.3f}%")

        # INT8 evaluation
        if int8_model is not None:
            # Use converted INT8 model for QAT checkpoints
            top1_q, top5_q = evaluate(int8_model, val_loader)
            print(f"INT8:   top1 = {top1_q:.3f}%, top5 = {top5_q:.3f}%")
            print(
                f"Loss:   top1 = {top1_fp - top1_q:.3f}%, top5 = {top5_fp - top5_q:.3f}%"
            )
        elif qscales is not None:
            # Use QDQ hooks for non-QAT checkpoints with scales
            q_handles = attach_qdq_hooks(model, qscales)
            top1_q, top5_q = evaluate(model, val_loader)
            for h in q_handles:
                h.remove()
            print(f"INT8(QDQ): top1 = {top1_q:.3f}%, top5 = {top5_q:.3f}%")
            print(
                f"Loss:   top1 = {top1_fp - top1_q:.3f}%, top5 = {top5_fp - top5_q:.3f}%"
            )
        else:
            print("No INT8 model or scales.json provided; skipping INT8 evaluation.")

    # Single-image dump (for qdq_error_report)
    if args.img is not None and args.dump_dir is not None:
        dump_dir = args.dump_dir
        print(f"Running single-image dump on {args.img}, saving to {dump_dir}")
        handles = register_dumps(model, dump_dir, quant_scales=qscales)

        img = Image.open(args.img).convert("RGB")
        x = mk_transform(args.img_size)(img)[None, ...]

        with torch.no_grad():
            logits = model(x)
            prob = torch.softmax(logits, dim=-1)
            topk = torch.topk(prob, k=5, dim=-1)

        os.makedirs(dump_dir, exist_ok=True)
        np.save(os.path.join(dump_dir, "logits.npy"), logits.cpu().numpy())
        np.save(
            os.path.join(dump_dir, "probs_topk_scores.npy"), topk.values.cpu().numpy()
        )
        np.save(
            os.path.join(dump_dir, "probs_topk_indices.npy"), topk.indices.cpu().numpy()
        )

        for h in handles:
            h.remove()


if __name__ == "__main__":
    main()
