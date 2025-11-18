import argparse, os, json, math, struct, sys, itertools

from types import SimpleNamespace
from collections import OrderedDict, defaultdict
from pathlib import Path

import torch
import torch.nn as nn
import torchvision.transforms as T
import torchvision.datasets as dsets
import numpy as np
from tqdm import tqdm

# Ensure project root (parent of `models`) is on sys.path
PROJECT_ROOT = Path(__file__).resolve().parents[2]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

# Local project imports
from models.core import build_model
from models.common.config import get_config, update_config
from models.core.tiny_vit import Conv2d_BN
from typing import Dict, Tuple, List, Optional

IMAGENET_MEAN = [0.485, 0.456, 0.406]
IMAGENET_STD  = [0.229, 0.224, 0.225]

def mk_transform(img_size: int):
    return T.Compose([
        T.Resize(256, interpolation=T.InterpolationMode.BICUBIC),
        T.CenterCrop(img_size),
        T.ToTensor(),
        T.Normalize(mean=IMAGENET_MEAN, std=IMAGENET_STD),
    ])

class PercentileObserver:
    def __init__(self, p: float = 99.0, eps: float = 1e-12):
        self.p = p
        self.eps = eps
        self.maxvals: List[float] = []

    @torch.no_grad()
    def observe(self, x: torch.Tensor):
        a = x.detach()
        a = a.float().abs()
        # robust against NaNs/Infs
        a = a[torch.isfinite(a)]
        if a.numel():
            self.maxvals.append(
                torch.quantile(a.flatten(), self.p / 100.0).item()
            )

    def scale_symmetric_int8(self) -> float:
        if len(self.maxvals) == 0:
            return 1.0
        m = float(np.median(self.maxvals))
        return max(m, self.eps) / 127.0

def fuse_conv_bn_weight_bias(
    conv_w: torch.Tensor,
    conv_bias: Optional[torch.Tensor],
    bn_w: torch.Tensor,
    bn_b: torch.Tensor,
    bn_running_mean: torch.Tensor,
    bn_running_var: torch.Tensor,
    bn_eps: float,
):
    # conv: bias may be None; bn params: w,b,running_mean,var
    if conv_bias is None:
        conv_bias = torch.zeros(
            conv_w.size(0), dtype=conv_w.dtype, device=conv_w.device
        )

    inv = bn_w / torch.sqrt(bn_running_var + bn_eps)
    w_fused = conv_w * inv.reshape(-1, 1, 1, 1)
    b_fused = bn_b + (conv_bias - bn_running_mean) * inv
    return w_fused.contiguous(), b_fused.contiguous()

def get_model_and_cfg(cfg_path: str, img_size: int, num_classes: int):
    # Build yacs config by mimicking CLI
    args = SimpleNamespace(
        cfg=cfg_path,
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
        tag="ptq",
        eval=False,
        throughput=False,
        local_rank=0,
    )

    config = get_config(args)

    # Overwrite a few fields explicitly
    config.defrost()
    config.DATA.IMG_SIZE = img_size
    config.MODEL.NUM_CLASSES = num_classes
    config.AMP_ENABLE = False
    config.freeze()

    model = build_model(config)
    model.eval()
    return model, config

def safe_load_checkpoint(model: nn.Module, ckpt_path: str):
    ckpt = torch.load(ckpt_path, map_location="cpu")
    state = ckpt.get("model", ckpt)
    msg = model.load_state_dict(state, strict=False)
    return str(msg)

def _extract_tensor(arg):
    if torch.is_tensor(arg):
        return arg
    if isinstance(arg, (list, tuple)):
        for item in arg:
            t = _extract_tensor(item)
            if t is not None:
                return t
    return None

def collect_activation_scales(
    model: nn.Module,
    loader,
    max_batches: Optional[int],
    percentile: float,
) -> Dict[str, float]:
    """
    Collect activation scales by observing MODULE OUTPUTS with a forward hook,
    so they match what cpu_golden_infer.py dumps and quantizes.
    """
    observers: Dict[str, PercentileObserver] = {}
    handles: List[torch.utils.hooks.RemovableHandle] = []

    def register(module: nn.Module, name: str):
        if any(
            isinstance(module, t)
            for t in [nn.Conv2d, nn.Linear, nn.GELU,
                      nn.BatchNorm2d, nn.LayerNorm, Conv2d_BN]
        ):
            observers[name] = PercentileObserver(p=percentile)

            def hook(_m, _inp, out):
                tensor = _extract_tensor(out)
                if tensor is not None:
                    observers[name].observe(tensor)

            # NOTE: changed from forward_pre_hook to forward_hook
            handles.append(module.register_forward_hook(hook))

    for n, m in model.named_modules():
        register(m, n)

    max_batches = max_batches if max_batches is not None and max_batches > 0 else None
    total_str = str(max_batches) if max_batches is not None else "all"

    iterable = loader
    if max_batches is not None:
        iterable = itertools.islice(loader, max_batches)

    with torch.no_grad():
        for x, _ in tqdm(
            iterable,
            total=max_batches if max_batches is not None else len(loader),
            desc=f"Calibration ({total_str} batches)",
            unit="batch",
        ):
            _ = model(x)

    for h in handles:
        h.remove()

    return {k: v.scale_symmetric_int8() for k, v in observers.items()}

def quant_per_channel_symmetric_int8(
    W: torch.Tensor, dim: int = 0, eps: float = 1e-12
) -> Tuple[torch.Tensor, np.ndarray]:
    # returns qW (int8), scales (float per-output-channel)
    Wf = W.detach().float()
    cdim = Wf.shape[dim]

    q: List[torch.Tensor] = []
    scales: List[float] = []

    for i in range(cdim):
        w = Wf.select(dim, i)
        amax = w.abs().max().item()
        s = max(amax, eps) / 127.0
        qi = torch.clamp((w / s).round(), -128, 127).to(torch.int8)
        q.append(qi.unsqueeze(dim))
        scales.append(s)

    qW = torch.cat(q, dim=dim).contiguous()
    return qW, np.array(scales, dtype=np.float32)

def quant_per_tensor_symmetric_int8(
    W: torch.Tensor, eps: float = 1e-12
) -> Tuple[torch.Tensor, float]:
    Wf = W.detach().float()
    amax = Wf.abs().max().item()
    s = max(amax, eps) / 127.0
    qW = torch.clamp((Wf / s).round(), -128, 127).to(torch.int8)
    return qW, float(s)

def export_int8_artifacts(
    model: nn.Module,
    act_scales: Dict[str, float],
    out_dir: str,
    per_channel: bool = True,
    align_bytes: int = 32,
):
    os.makedirs(out_dir, exist_ok=True)

    weight_path = os.path.join(out_dir, "weights.bin")
    manifest: List[Dict] = []
    offset = 0

    def align_off(off: int) -> Tuple[int, int]:
        pad = (align_bytes - (off % align_bytes)) % align_bytes
        return off + pad, pad

    with open(weight_path, "wb") as fbin:
        for name, module in model.named_modules():
            entry = None

            # Fused Conv2d_BN
            if isinstance(module, Conv2d_BN):
                conv = module.c
                bn = module.bn
                Wf, bf = fuse_conv_bn_weight_bias(
                    conv.weight,
                    None,
                    bn.weight,
                    bn.bias,
                    bn.running_mean,
                    bn.running_var,
                    bn.eps,
                )

                if per_channel:
                    qW, w_scales = quant_per_channel_symmetric_int8(Wf, dim=0)
                else:
                    qW, s = quant_per_tensor_symmetric_int8(Wf)
                    w_scales = np.array([s], dtype=np.float32)

                # bias quant to int32 using activation scale if available (s_a) and per-out s_w
                s_a = act_scales.get(name, 1.0)

                if per_channel:
                    bq = np.round(
                        bf.detach().float().cpu().numpy()
                        / (w_scales * s_a)
                    ).astype(np.int32)
                else:
                    bq = np.round(
                        bf.detach().float().cpu().numpy()
                        / (w_scales[0] * s_a)
                    ).astype(np.int32)

                off_aligned, pad = align_off(offset)
                if pad:
                    fbin.write(b"\x00" * pad)

                wbytes = qW.detach().cpu().numpy().tobytes(order="C")
                fbin.write(wbytes)
                nbytes = len(wbytes)

                entry = dict(
                    name=name,
                    type="Conv2d_BN(fused)",
                    weight_shape=list(Wf.shape),
                    weight_offset=off_aligned,
                    weight_nbytes=nbytes,
                    weight_scale=w_scales.tolist(),
                    activation_scale=float(s_a),
                    bias_dtype="int32",
                    bias=bq.tolist(),
                    groups=int(conv.groups),
                    stride=list(conv.stride),
                    padding=list(conv.padding),
                    dilation=list(conv.dilation),
                )

                offset = off_aligned + nbytes

            # Plain Conv2d (not expected here, but support anyway)
            elif isinstance(module, nn.Conv2d):
                Wf = module.weight

                if per_channel:
                    qW, w_scales = quant_per_channel_symmetric_int8(Wf, dim=0)
                else:
                    qW, s = quant_per_tensor_symmetric_int8(Wf)
                    w_scales = np.array([s], dtype=np.float32)

                s_a = act_scales.get(name, 1.0)

                if module.bias is not None:
                    if per_channel:
                        bq = np.round(
                            module.bias.detach().float().cpu().numpy()
                            / (w_scales * s_a)
                        ).astype(np.int32)
                    else:
                        bq = np.round(
                            module.bias.detach().float().cpu().numpy()
                            / (w_scales[0] * s_a)
                        ).astype(np.int32)
                    bq = bq.tolist()
                else:
                    bq = None

                off_aligned, pad = align_off(offset)
                if pad:
                    fbin.write(b"\x00" * pad)

                wbytes = qW.detach().cpu().numpy().tobytes(order="C")
                fbin.write(wbytes)
                nbytes = len(wbytes)

                entry = dict(
                    name=name,
                    type="Conv2d",
                    weight_shape=list(Wf.shape),
                    weight_offset=off_aligned,
                    weight_nbytes=nbytes,
                    weight_scale=w_scales.tolist(),
                    activation_scale=float(s_a),
                    bias_dtype="int32" if bq is not None else None,
                    bias=bq,
                    groups=int(module.groups),
                    stride=list(module.stride),
                    padding=list(module.padding),
                    dilation=list(module.dilation),
                )

                offset = off_aligned + nbytes

            elif isinstance(module, nn.Linear):
                Wf = module.weight  # [out, in]

                # per-out-channel for Linear along dim=0
                if per_channel:
                    qW, w_scales = quant_per_channel_symmetric_int8(Wf, dim=0)
                else:
                    qW, s = quant_per_tensor_symmetric_int8(Wf)
                    w_scales = np.array([s], dtype=np.float32)

                s_a = act_scales.get(name, 1.0)

                if module.bias is not None:
                    if per_channel:
                        bq = np.round(
                            module.bias.detach().float().cpu().numpy()
                            / (w_scales * s_a)
                        ).astype(np.int32)
                    else:
                        bq = np.round(
                            module.bias.detach().float().cpu().numpy()
                            / (w_scales[0] * s_a)
                        ).astype(np.int32)
                    bq = bq.tolist()
                else:
                    bq = None

                off_aligned, pad = align_off(offset)
                if pad:
                    fbin.write(b"\x00" * pad)

                wbytes = qW.detach().cpu().numpy().tobytes(order="C")
                fbin.write(wbytes)
                nbytes = len(wbytes)

                entry = dict(
                    name=name,
                    type="Linear",
                    weight_shape=list(Wf.shape),
                    weight_offset=off_aligned,
                    weight_nbytes=nbytes,
                    weight_scale=w_scales.tolist(),
                    activation_scale=float(s_a),
                    bias_dtype="int32" if bq is not None else None,
                    bias=bq,
                )

                offset = off_aligned + nbytes

            if entry is not None:
                manifest.append(entry)

    # write scales.json
    with open(os.path.join(out_dir, "scales.json"), "w") as jf:
        json.dump(
            {
                "format": "tinyvit-int8-v1",
                "weights_bin": "weights.bin",
                "layers": manifest,
                "preprocess": {
                    "mean": IMAGENET_MEAN,
                    "std": IMAGENET_STD,
                },
            },
            jf,
            indent=2,
        )

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--cfg",
        required=True,
        help="path to tiny_vit_5m.yaml",
    )
    ap.add_argument(
        "--ckpt",
        required=True,
        help='path to FP checkpoint (.pth with key "model")',
    )
    ap.add_argument(
        "--calib-dir",
        required=True,
        help="ImageFolder directory for calibration",
    )
    ap.add_argument(
        "--img-size",
        type=int,
        default=224,
    )
    ap.add_argument(
        "--num-classes",
        type=int,
        default=1000,
    )
    ap.add_argument(
        "--calib-batches",
        type=int,
        default=0,
        help="Number of calibration batches (<=0 means use entire set)",
    )
    ap.add_argument(
        "--batch-size",
        type=int,
        default=16,
    )
    ap.add_argument(
        "--per-channel",
        action="store_true",
        default=True,
    )
    ap.add_argument(
        "--observer-percentile",
        type=float,
        default=99.0,
        help="Percentile used by activation observers (e.g., 98-99.9)",
    )
    ap.add_argument(
        "--out-dir",
        required=True,
    )

    args = ap.parse_args()

    # Build model (CPU) and load FP weights
    model, cfg = get_model_and_cfg(args.cfg, args.img_size, args.num_classes)
    print(safe_load_checkpoint(model, args.ckpt))

    # Calibration loader
    tfm = mk_transform(args.img_size)
    calib = dsets.ImageFolder(args.calib_dir, transform=tfm)
    loader = torch.utils.data.DataLoader(
        calib,
        batch_size=args.batch_size,
        shuffle=False,
        num_workers=10,
        pin_memory=False,
    )

    # Collect activation scales
    max_batches = args.calib_batches if args.calib_batches > 0 else None
    act_scales = collect_activation_scales(
        model,
        loader,
        max_batches=max_batches,
        percentile=args.observer_percentile,
    )

    # Export INT8 weights + scales
    export_int8_artifacts(
        model,
        act_scales,
        args.out_dir,
        per_channel=args.per_channel,
    )

if __name__ == "__main__":
    main()
