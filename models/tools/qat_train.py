import argparse, os, copy, sys
from types import SimpleNamespace
from pathlib import Path

import torch
import torch.nn as nn
import torch.optim as optim
import torchvision.transforms as T
import torchvision.datasets as dsets

from torch.ao.quantization import get_default_qat_qconfig, QConfigMapping
from torch.ao.quantization.quantize_fx import prepare_qat_fx, convert_fx
from tqdm import tqdm
import warnings

# Suppress warnings from quantization modules
warnings.filterwarnings("ignore", category=UserWarning)
warnings.filterwarnings("ignore", category=DeprecationWarning)

# Ensure project root on sys.path
PROJECT_ROOT = Path(__file__).resolve().parents[2]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from models.core import build_model
from models.common.config import get_config

IMAGENET_MEAN = [0.485, 0.456, 0.406]
IMAGENET_STD = [0.229, 0.224, 0.225]

def mk_train_tfm(img_size):
    return T.Compose([
        T.RandomResizedCrop(img_size, scale=(0.08, 1.0), interpolation=T.InterpolationMode.BICUBIC),
        T.RandomHorizontalFlip(),
        T.ToTensor(),
        T.Normalize(IMAGENET_MEAN, IMAGENET_STD),
    ])

def mk_val_tfm(img_size):
    return T.Compose([
        T.Resize(256, interpolation=T.InterpolationMode.BICUBIC),
        T.CenterCrop(img_size),
        T.ToTensor(),
        T.Normalize(IMAGENET_MEAN, IMAGENET_STD),
    ])

def build_model_and_cfg(cfg_path: str, img_size: int, num_classes: int):
    args = SimpleNamespace(
        cfg=cfg_path, opts=None, batch_size=None, data_path=None,
        pretrained=None, resume=None, accumulation_steps=None,
        use_checkpoint=False, disable_amp=True, only_cpu=True,
        output="output", tag="qat", eval=False, throughput=False, local_rank=0,
    )
    cfg = get_config(args)
    cfg.defrost()
    cfg.DATA.IMG_SIZE = img_size
    cfg.MODEL.NUM_CLASSES = num_classes
    cfg.AMP_ENABLE = False
    cfg.freeze()
    model = build_model(cfg)
    return model, cfg

@torch.no_grad()
def evaluate(model, loader, device):
    model.eval()
    top1 = top5 = n = 0
    tbar = tqdm(loader, desc="val", leave=False)
    for x, y in tbar:
        x, y = x.to(device), y.to(device)
        logits = model(x)
        acc1, acc5 = accuracy(logits, y)
        bs = x.size(0)
        top1 += acc1.item() * bs
        top5 += acc5.item() * bs
        n += bs
        tbar.set_postfix(top1=top1 / n if n else 0.0)
    return (top1 / n) if n else 0.0, (top5 / n) if n else 0.0

def accuracy(output, target, topk=(1, 5)):
    maxk = max(topk)
    _, pred = output.topk(maxk, 1, True, True)
    pred = pred.t()
    correct = pred.eq(target.view(1, -1).expand_as(pred))
    res = []
    for k in topk:
        correct_k = correct[:k].reshape(-1).float().sum(0, keepdim=True)
        res.append(correct_k.mul_(100.0 / target.size(0)))
    return res

def train_one_epoch(model, loader, criterion, optimizer, device):
    model.train()
    loss_sum = n = 0
    tbar = tqdm(loader, desc="train", leave=False)
    for x, y in tbar:
        x, y = x.to(device), y.to(device)
        optimizer.zero_grad(set_to_none=True)
        logits = model(x)
        loss = criterion(logits, y)
        loss.backward()
        optimizer.step()
        bs = x.size(0)
        loss_sum += loss.item() * bs
        n += bs
        tbar.set_postfix(loss=loss.item())
    return loss_sum / n if n else 0.0

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cfg", required=True, help="TinyViT config yaml")
    ap.add_argument("--train-dir", required=True, help="ImageFolder root for training")
    ap.add_argument("--val-dir", required=True, help="ImageFolder root for validation")
    ap.add_argument("--ckpt", default=None, help="Optional FP32 checkpoint to fine-tune from")
    ap.add_argument("--out-dir", required=True, help="Where to save QAT checkpoints")
    ap.add_argument("--epochs", type=int, default=10)
    ap.add_argument("--batch-size", type=int, default=64)
    ap.add_argument("--lr", type=float, default=1e-4)
    ap.add_argument("--img-size", type=int, default=224)
    ap.add_argument("--num-classes", type=int, default=1000)
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--save-converted", action="store_true",
                    help="Also export a fully converted INT8 model for sanity checks")
    args = ap.parse_args()

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    os.makedirs(args.out_dir, exist_ok=True)

    # Data
    train_ds = dsets.ImageFolder(args.train_dir, transform=mk_train_tfm(args.img_size))
    val_ds = dsets.ImageFolder(args.val_dir, transform=mk_val_tfm(args.img_size))
    train_loader = torch.utils.data.DataLoader(
        train_ds, batch_size=args.batch_size, shuffle=True,
        num_workers=args.workers, pin_memory=True,
    )
    val_loader = torch.utils.data.DataLoader(
        val_ds, batch_size=args.batch_size, shuffle=False,
        num_workers=args.workers, pin_memory=True,
    )

    # Model build/load
    float_model, _ = build_model_and_cfg(args.cfg, args.img_size, args.num_classes)
    if args.ckpt:
        ckpt = torch.load(args.ckpt, map_location="cpu")
        state = ckpt.get("model", ckpt)
        msg = float_model.load_state_dict(state, strict=False)
        print("Loaded ckpt:", msg)

    # QAT prep (FX)
    example_inputs = (torch.randn(1, 3, args.img_size, args.img_size),)
    qconfig = get_default_qat_qconfig("fbgemm")
    qconfig_mapping = QConfigMapping().set_global(qconfig)
    prepared = prepare_qat_fx(copy.deepcopy(float_model), qconfig_mapping, example_inputs)
    prepared.to(device)

    criterion = nn.CrossEntropyLoss()
    optimizer = optim.AdamW(prepared.parameters(), lr=args.lr)

    best_top1 = 0.0
    for epoch in range(args.epochs):
        print(f"Epoch {epoch+1}/{args.epochs}")
        train_loss = train_one_epoch(prepared, train_loader, criterion, optimizer, device)
        top1, top5 = evaluate(prepared, val_loader, device)
        print(f"[Epoch {epoch+1}/{args.epochs}] loss={train_loss:.4f} top1={top1:.3f} top5={top5:.3f}")

        # Save best fake-quant (QAT) checkpoint
        if top1 > best_top1:
            best_top1 = top1
            torch.save(
                {"model": prepared.state_dict(), "epoch": epoch + 1, "top1": top1, "top5": top5},
                os.path.join(args.out_dir, "qat_best.pth"),
            )

    # Convert to a true INT8 model for a quick sanity eval or test export
    if args.save_converted:
        converted = convert_fx(prepared.cpu())
        torch.save(converted.state_dict(), os.path.join(args.out_dir, "qat_int8_converted.pth"))
        print("Saved converted INT8 model (FX)")

if __name__ == "__main__":
    main()
