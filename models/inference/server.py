"""
FastAPI server for real-time TinyViT video classification.

Endpoints:
- GET  /health         - Health check
- POST /predict        - Single image classification
- POST /predict/video  - Video file classification
- WS   /ws/video       - Real-time video streaming via WebSocket
"""
import argparse
import json
import sys
import copy
import warnings
from pathlib import Path
from typing import List, Optional, Dict, Any, Tuple
from io import BytesIO

import torch
import torch.nn as nn
import numpy as np
from PIL import Image

# FastAPI imports
from fastapi import FastAPI, File, UploadFile, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
import uvicorn

# Suppress warnings
warnings.filterwarnings("ignore", category=UserWarning)
warnings.filterwarnings("ignore", category=DeprecationWarning)

# Ensure project root is on path
PROJECT_ROOT = Path(__file__).resolve().parents[2]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from models.core import build_model
from models.common.config import get_config
from models.inference.video_processor import (
    VideoProcessor, 
    extract_frames_from_bytes, 
    FPSCounter,
    FrameInfo
)

# QAT imports
from torch.ao.quantization import get_default_qat_qconfig, QConfigMapping
from torch.ao.quantization.quantize_fx import prepare_qat_fx, convert_fx

import torchvision.transforms as T

# ImageNet normalization constants
IMAGENET_MEAN = [0.485, 0.456, 0.406]
IMAGENET_STD = [0.229, 0.224, 0.225]

# Global model and config
_model: Optional[nn.Module] = None
_transform: Optional[T.Compose] = None
_class_names: Optional[List[str]] = None
_device: str = "cpu"


def get_transform(img_size: int = 224) -> T.Compose:
    """Get preprocessing transform matching training pipeline."""
    return T.Compose([
        T.Resize(256, interpolation=T.InterpolationMode.BICUBIC),
        T.CenterCrop(img_size),
        T.ToTensor(),
        T.Normalize(IMAGENET_MEAN, IMAGENET_STD),
    ])


def is_qat_state(state: Dict[str, Any]) -> bool:
    """Check if a state dict contains QAT (fake quant) keys."""
    return any("weight_fake_quant" in k for k in state.keys())


def resolve_device(is_qat: bool, device: str) -> str:
    """Resolve device for inference based on checkpoint type."""
    if device == "cuda" and not torch.cuda.is_available():
        raise RuntimeError("CUDA requested but not available.")
    if is_qat and device != "cpu":
        print("[Server] QAT INT8 inference is CPU-only. Forcing device=cpu.")
        return "cpu"
    return device


def configure_quant_engine() -> str:
    """Select a supported quantization engine for INT8 conversion."""
    preferred = ["fbgemm", "qnnpack"]
    for engine in preferred:
        if engine in torch.backends.quantized.supported_engines:
            torch.backends.quantized.engine = engine
            return engine
    raise RuntimeError(
        "No supported quantized engine found. "
        "Available engines: "
        f"{torch.backends.quantized.supported_engines}"
    )


def load_model(
    cfg_path: str,
    ckpt_path: str,
    img_size: int = 224,
    num_classes: int = 1000,
    device: str = "cpu"
) -> Tuple[nn.Module, str]:
    """
    Load TinyViT model from checkpoint.
    
    Supports both FP32 and QAT checkpoints.
    """
    from types import SimpleNamespace
    
    args_ns = SimpleNamespace(
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
        tag="infer",
        eval=True,
        throughput=False,
        local_rank=0,
    )
    
    cfg = get_config(args_ns)
    cfg.defrost()
    cfg.DATA.IMG_SIZE = img_size
    cfg.MODEL.NUM_CLASSES = num_classes
    cfg.AMP_ENABLE = False
    cfg.freeze()
    
    float_model = build_model(cfg)

    ckpt = torch.load(ckpt_path, map_location="cpu", weights_only=False)
    state = ckpt.get("model", ckpt)
    is_qat = is_qat_state(state)
    device = resolve_device(is_qat, device)

    # Handle QAT vs FP32 checkpoints
    if is_qat:
        print(f"[Server] Loading QAT checkpoint from {ckpt_path}")
        engine = configure_quant_engine()
        print(f"[Server] Using quantized engine: {engine}")
        example_inputs = (torch.randn(1, 3, img_size, img_size),)
        qconfig = get_default_qat_qconfig(engine)
        qconfig_mapping = QConfigMapping().set_global(qconfig)
        prepared = prepare_qat_fx(copy.deepcopy(float_model), qconfig_mapping, example_inputs)

        prepared.load_state_dict(state, strict=False)
        
        # Try to convert to INT8, fall back to FP32 if conversion fails
        # (Issue on Apple Silicon / ARM with qnnpack backend)
        try:
            model = convert_fx(prepared.cpu())
            print("[Server] Successfully converted to INT8 quantized model")
        except RuntimeError as e:
            print(f"[Server] Warning: INT8 conversion failed ({e})")
            print("[Server] Falling back to FP32 inference (QAT fake-quant model)")
            # Use the prepared model directly - runs in FP32 with fake quantization
            model = prepared
    else:
        print(f"[Server] Loading FP32 checkpoint from {ckpt_path}")
        float_model.load_state_dict(state, strict=False)
        model = float_model
    
    model.to(device)
    model.eval()
    return model, device


def preprocess_image(image: Image.Image) -> torch.Tensor:
    """Preprocess PIL image for model input."""
    global _transform
    if _transform is None:
        _transform = get_transform()
    return _transform(image).unsqueeze(0)


def preprocess_frame(frame: np.ndarray) -> torch.Tensor:
    """Preprocess numpy frame (RGB) for model input."""
    image = Image.fromarray(frame)
    return preprocess_image(image)


@torch.no_grad()
def predict(
    image_tensor: torch.Tensor,
    top_k: int = 5
) -> Dict[str, Any]:
    """
    Run inference on preprocessed image tensor.
    
    Returns dict with predictions and confidence scores.
    """
    global _model, _class_names, _device
    
    if _model is None:
        raise RuntimeError("Model not loaded")
    
    image_tensor = image_tensor.to(_device)
    logits = _model(image_tensor)
    probs = torch.softmax(logits, dim=-1)
    
    k = min(max(int(top_k), 0), probs.shape[-1])
    if k == 0:
        return {"predictions": [], "top_class": None, "top_confidence": 0.0}

    top_probs, top_indices = torch.topk(probs, k=k, dim=-1)
    
    predictions = []
    for i in range(k):
        idx = top_indices[0, i].item()
        prob = top_probs[0, i].item()
        label = _class_names[idx] if _class_names else f"class_{idx}"
        predictions.append({
            "class_id": idx,
            "label": label,
            "confidence": round(prob, 4)
        })
    
    return {
        "predictions": predictions,
        "top_class": predictions[0]["label"] if predictions else None,
        "top_confidence": predictions[0]["confidence"] if predictions else 0.0
    }


def load_imagenet_labels(path: Optional[str] = None) -> List[str]:
    """Load ImageNet class labels."""
    # Check explicit path first
    if path and Path(path).exists():
        with open(path) as f:
            labels = [line.strip() for line in f]
            print(f"[Server] Loaded {len(labels)} class labels from {path}")
            return labels
    
    # Check for bundled labels file
    bundled_path = Path(__file__).parent / "imagenet_labels.txt"
    if bundled_path.exists():
        with open(bundled_path) as f:
            labels = [line.strip() for line in f]
            print(f"[Server] Loaded {len(labels)} ImageNet class labels")
            return labels
    
    # Default: numeric labels
    print("[Server] Warning: No labels file found, using numeric class IDs")
    return [f"class_{i}" for i in range(1000)]


# FastAPI Application
app = FastAPI(
    title="TinyViT Video Inference API",
    description="Real-time image classification using quantized TinyViT-5M",
    version="1.0.0"
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
async def health_check():
    """Health check endpoint."""
    return {
        "status": "healthy",
        "model_loaded": _model is not None,
        "device": _device
    }


@app.post("/predict")
async def predict_image(
    file: UploadFile = File(...),
    top_k: int = 5
):
    """
    Classify a single image.
    
    - **file**: Image file (JPEG, PNG)
    - **top_k**: Number of top predictions to return
    """
    try:
        contents = await file.read()
        image = Image.open(BytesIO(contents)).convert("RGB")
        tensor = preprocess_image(image)
        result = predict(tensor, top_k=top_k)
        return JSONResponse(content=result)
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.post("/predict/video")
async def predict_video(
    file: UploadFile = File(...),
    target_fps: float = 5.0,
    max_frames: int = 100,
    top_k: int = 3
):
    """
    Classify frames from a video file.
    
    - **file**: Video file (MP4, AVI, MOV, WebM)
    - **target_fps**: Target frame rate for extraction
    - **max_frames**: Maximum number of frames to process
    - **top_k**: Number of top predictions per frame
    """
    try:
        contents = await file.read()
        frames = extract_frames_from_bytes(
            contents,
            target_fps=target_fps,
            max_frames=max_frames
        )
        
        results = []
        for frame_info in frames:
            tensor = preprocess_frame(frame_info.frame)
            pred = predict(tensor, top_k=top_k)
            results.append({
                "frame_number": frame_info.frame_number,
                "timestamp_ms": round(frame_info.timestamp_ms, 2),
                **pred
            })
        
        return JSONResponse(content={
            "total_frames": len(results),
            "frames": results
        })
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.websocket("/ws/video")
async def websocket_video(websocket: WebSocket):
    """
    Real-time video classification via WebSocket.
    
    Protocol:
    - Client sends: base64-encoded JPEG frames or raw bytes
    - Server responds: JSON with predictions
    
    Message format (client -> server):
        {"type": "frame", "data": "<base64_jpeg>"}
        or raw JPEG bytes
    
    Message format (server -> client):
        {"type": "prediction", "predictions": [...], "fps": 5.2}
    """
    await websocket.accept()
    fps_counter = FPSCounter(window_size=30)
    
    try:
        while True:
            # Receive frame data
            data = await websocket.receive()
            
            if "bytes" in data:
                # Raw JPEG bytes
                image_bytes = data["bytes"]
            elif "text" in data:
                # JSON message with base64 data
                msg = json.loads(data["text"])
                if msg.get("type") == "frame":
                    import base64
                    image_bytes = base64.b64decode(msg["data"])
                elif msg.get("type") == "close":
                    break
                else:
                    continue
            else:
                continue
            
            # Process frame
            try:
                image = Image.open(BytesIO(image_bytes)).convert("RGB")
                tensor = preprocess_image(image)
                result = predict(tensor, top_k=3)
                
                fps = fps_counter.tick()
                
                await websocket.send_json({
                    "type": "prediction",
                    "fps": round(fps, 1),
                    **result
                })
            except Exception as e:
                await websocket.send_json({
                    "type": "error",
                    "message": str(e)
                })
                
    except WebSocketDisconnect:
        print("[WebSocket] Client disconnected")
    except Exception as e:
        print(f"[WebSocket] Error: {e}")
        await websocket.close()


def init_model(
    cfg_path: str,
    ckpt_path: str,
    img_size: int = 224,
    num_classes: int = 1000,
    labels_path: Optional[str] = None,
    device: str = "cpu"
):
    """Initialize global model for inference."""
    global _model, _transform, _class_names, _device
    
    _transform = get_transform(img_size)
    _class_names = load_imagenet_labels(labels_path)
    _model, _device = load_model(cfg_path, ckpt_path, img_size, num_classes, device)
    
    print(f"[Server] Model loaded successfully on {device}")
    print(f"[Server] Input size: {img_size}x{img_size}")
    print(f"[Server] Number of classes: {num_classes}")


def main():
    parser = argparse.ArgumentParser(description="TinyViT Inference Server")
    parser.add_argument(
        "--cfg",
        default="models/configs/tiny_vit_5m.yaml",
        help="Model config path"
    )
    parser.add_argument(
        "--ckpt",
        default="models/checkpoints/qat_int8/qat_best.pth",
        help="Model checkpoint path"
    )
    parser.add_argument("--img-size", type=int, default=224)
    parser.add_argument("--num-classes", type=int, default=1000)
    parser.add_argument("--labels", default=None, help="Path to class labels file")
    parser.add_argument("--device", default="cpu", choices=["cpu", "cuda"])
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8000)
    
    args = parser.parse_args()
    
    # Initialize model
    init_model(
        cfg_path=args.cfg,
        ckpt_path=args.ckpt,
        img_size=args.img_size,
        num_classes=args.num_classes,
        labels_path=args.labels,
        device=args.device
    )
    
    # Start server
    print(f"[Server] Starting on http://{args.host}:{args.port}")
    print(f"[Server] API docs: http://{args.host}:{args.port}/docs")
    
    uvicorn.run(app, host=args.host, port=args.port)


if __name__ == "__main__":
    main()
