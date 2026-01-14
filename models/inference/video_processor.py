"""
Video processing utilities for real-time inference.
"""
import cv2
import numpy as np
from typing import Generator, Tuple, Optional, List, Union
from dataclasses import dataclass
import time


@dataclass
class FrameInfo:
    """Container for frame data and metadata."""
    frame: np.ndarray
    timestamp_ms: float
    frame_number: int


class VideoProcessor:
    """
    Video processor for extracting and preprocessing frames.
    
    Supports:
    - Video files (MP4, AVI, MOV, WebM)
    - Webcam capture
    - Frame skipping for real-time performance
    """
    
    def __init__(
        self,
        source: Union[str, int],
        target_fps: Optional[float] = None,
        max_dimension: Optional[int] = None
    ):
        """
        Initialize video processor.
        
        Args:
            source: Video file path or camera index (0 for default webcam)
            target_fps: Target FPS for frame extraction (None = use source FPS)
            max_dimension: Maximum dimension for frame resizing (None = no resize)
        """
        self.source = source
        self.target_fps = target_fps
        self.max_dimension = max_dimension
        self.cap: Optional[cv2.VideoCapture] = None
        
    def open(self) -> bool:
        """Open video source. Returns True on success."""
        self.cap = cv2.VideoCapture(self.source)
        return self.cap.isOpened()
    
    def close(self):
        """Release video capture resources."""
        if self.cap is not None:
            self.cap.release()
            self.cap = None
    
    @property
    def source_fps(self) -> float:
        """Get source video FPS."""
        if self.cap is None:
            return 0.0
        return self.cap.get(cv2.CAP_PROP_FPS) or 30.0
    
    @property
    def frame_count(self) -> int:
        """Get total frame count (0 for live sources)."""
        if self.cap is None:
            return 0
        count = int(self.cap.get(cv2.CAP_PROP_FRAME_COUNT))
        return max(0, count)
    
    @property
    def resolution(self) -> Tuple[int, int]:
        """Get source resolution as (width, height)."""
        if self.cap is None:
            return (0, 0)
        w = int(self.cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        h = int(self.cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        return (w, h)
    
    def _resize_frame(self, frame: np.ndarray) -> np.ndarray:
        """Resize frame if max_dimension is set."""
        if self.max_dimension is None:
            return frame
        h, w = frame.shape[:2]
        if max(h, w) <= self.max_dimension:
            return frame
        scale = self.max_dimension / max(h, w)
        new_w, new_h = int(w * scale), int(h * scale)
        return cv2.resize(frame, (new_w, new_h), interpolation=cv2.INTER_LINEAR)
    
    def frames(self) -> Generator[FrameInfo, None, None]:
        """
        Generator yielding frames from the video source.
        
        Automatically handles frame skipping based on target_fps.
        """
        if self.cap is None or not self.cap.isOpened():
            if not self.open():
                raise RuntimeError(f"Failed to open video source: {self.source}")
        
        source_fps = self.source_fps
        skip_interval = 1
        if self.target_fps is not None and source_fps > self.target_fps:
            skip_interval = int(source_fps / self.target_fps)
        
        frame_number = 0
        while True:
            ret, frame = self.cap.read()
            if not ret:
                break
            
            # Skip frames to match target FPS
            if frame_number % skip_interval == 0:
                timestamp_ms = self.cap.get(cv2.CAP_PROP_POS_MSEC)
                frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                frame_rgb = self._resize_frame(frame_rgb)
                
                yield FrameInfo(
                    frame=frame_rgb,
                    timestamp_ms=timestamp_ms,
                    frame_number=frame_number
                )
            
            frame_number += 1
    
    def __enter__(self):
        self.open()
        return self
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()
        return False


def extract_frames_from_bytes(
    video_bytes: bytes,
    target_fps: Optional[float] = None,
    max_frames: Optional[int] = None
) -> List[FrameInfo]:
    """
    Extract frames from video bytes (e.g., from file upload).
    
    Args:
        video_bytes: Raw video file bytes
        target_fps: Target FPS for extraction
        max_frames: Maximum number of frames to extract
        
    Returns:
        List of FrameInfo objects
    """
    import tempfile
    import os
    
    # Write to temp file (OpenCV needs file path)
    with tempfile.NamedTemporaryFile(suffix='.mp4', delete=False) as f:
        f.write(video_bytes)
        temp_path = f.name
    
    try:
        frames = []
        with VideoProcessor(temp_path, target_fps=target_fps) as processor:
            for frame_info in processor.frames():
                frames.append(frame_info)
                if max_frames is not None and len(frames) >= max_frames:
                    break
        return frames
    finally:
        os.unlink(temp_path)


class FPSCounter:
    """Simple FPS counter for performance monitoring."""
    
    def __init__(self, window_size: int = 30):
        self.window_size = window_size
        self.timestamps: List[float] = []
    
    def tick(self) -> float:
        """Record a frame and return current FPS."""
        now = time.time()
        self.timestamps.append(now)
        
        # Keep only recent timestamps
        if len(self.timestamps) > self.window_size:
            self.timestamps = self.timestamps[-self.window_size:]
        
        if len(self.timestamps) < 2:
            return 0.0
        
        elapsed = self.timestamps[-1] - self.timestamps[0]
        if elapsed <= 0:
            return 0.0
        
        return (len(self.timestamps) - 1) / elapsed
