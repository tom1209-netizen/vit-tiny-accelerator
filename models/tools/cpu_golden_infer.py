import argparse, os, json, sys
import torch
import torch.nn as nn
import numpy as np
from types import SimpleNamespace
from pathlib import Path

# Ensure project root (parent of `models`) is on sys.path when running as a script
PROJECT_ROOT = Path(__file__).resolve().parents[2]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from models.core import build_model
from models.common.config import get_config
from models.core.tiny_vit import Conv2d_BN

import torchvision.transforms as T
from PIL import Image

IMAGENET_MEAN = [0.485, 0.456, 0.406]
IMAGENET_STD  = [0.229, 0.224, 0.225]

def mk_transform(img_size: int):
    return T.Compose([
        T.Resize(256, interpolation=T.InterpolationMode.BICUBIC),
        T.CenterCrop(img_size),
        T.ToTensor(),
        T.Normalize(IMAGENET_MEAN, IMAGENET_STD),
    ])

def safe_load_checkpoint(model: nn.Module, ckpt_path: str):
    ckpt = torch.load(ckpt_path, map_location='cpu')
    state = ckpt.get('model', ckpt)
    msg = model.load_state_dict(state, strict=False)
    return str(msg)

def load_scales(path):
    if path is None: return None
    with open(path, 'r') as f:
        j = json.load(f)
    # map name -> (act_scale, weight_scales list)
    name_to = {}
    for lyr in j['layers']:
        name_to[lyr['name']] = dict(
            act=float(lyr.get('activation_scale', 1.0)),
            w_scales=lyr.get('weight_scale', None),
            type=lyr['type']
        )
    return name_to

def qdq(x: torch.Tensor, s: float) -> torch.Tensor:
    if s is None or s <= 0: return x
    q = torch.clamp((x / s).round(), -128, 127)
    return q * s

def register_dumps(model: nn.Module, out_dir: str, quant_scales=None):
    os.makedirs(out_dir, exist_ok=True)
    handles = []
    counter = {'i': 0}

    def hook_maker(name: str):
        def h(_m, _in, out):
            y = out[0] if isinstance(out, tuple) else out
            if not torch.is_tensor(y): return
            idx = counter['i']; counter['i'] += 1
            ycpu = y.detach().cpu().float()
            np.save(os.path.join(out_dir, f'{idx:04d}_{name.replace(".","_")}.npy'), ycpu.numpy())
            # optional quantized view via activation scale
            if quant_scales is not None and name in quant_scales:
                s = quant_scales[name]['act']
                yq = qdq(ycpu, s)
                np.save(os.path.join(out_dir, f'{idx:04d}_{name.replace(".","_")}_qdq.npy'), yq.numpy())
        return h

    for n, m in model.named_modules():
        if isinstance(m, (nn.Conv2d, nn.Linear, nn.GELU, nn.BatchNorm2d, nn.LayerNorm, Conv2d_BN)):
            handles.append(m.register_forward_hook(hook_maker(n)))
    return handles

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--cfg', required=True)
    ap.add_argument('--ckpt', required=True)
    ap.add_argument('--img', required=True)
    ap.add_argument('--img-size', type=int, default=224)
    ap.add_argument('--num-classes', type=int, default=1000)
    ap.add_argument('--dump-dir', required=True)
    ap.add_argument('--scales-json', default=None, help='optional: enable *_qdq.npy dumps')
    args = ap.parse_args()

    # Build model/cfg and load weights
    args_ns = SimpleNamespace(
        cfg=args.cfg, opts=None, batch_size=None, data_path=None, pretrained=None, resume=None,
        accumulation_steps=None, use_checkpoint=False, disable_amp=True, only_cpu=True,
        output='output', tag='infer', eval=True, throughput=False, local_rank=0
    )
    cfg = get_config(args_ns)
    cfg.defrost(); cfg.DATA.IMG_SIZE = args.img_size; cfg.MODEL.NUM_CLASSES = args.num_classes; cfg.AMP_ENABLE=False; cfg.freeze()
    model = build_model(cfg).eval()
    print(safe_load_checkpoint(model, args.ckpt))

    # Hooks
    qscales = load_scales(args.scales_json)
    handles = register_dumps(model, args.dump_dir, quant_scales=qscales)

    # Preprocess and run
    img = Image.open(args.img).convert('RGB')
    x = mk_transform(args.img_size)(img)[None, ...]
    with torch.no_grad():
        logits = model(x)
        prob = torch.softmax(logits, dim=-1)
        topk = torch.topk(prob, k=5, dim=-1)
        np.save(os.path.join(args.dump_dir, 'logits.npy'), logits.cpu().numpy())
        np.save(os.path.join(args.dump_dir, 'probs_topk_scores.npy'), topk.values.cpu().numpy())
        np.save(os.path.join(args.dump_dir, 'probs_topk_indices.npy'), topk.indices.cpu().numpy())

    for h in handles:
        h.remove()

if __name__ == '__main__':
    main()
