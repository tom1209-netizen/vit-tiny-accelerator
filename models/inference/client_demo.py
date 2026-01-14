"""
Demo client for TinyViT video inference.

Supports:
- Webcam streaming to server via WebSocket
- Video file streaming
- Real-time prediction overlay display
"""
import argparse
import asyncio
import base64
import json
import time
import sys
from pathlib import Path
from typing import Optional, Union

import cv2
import numpy as np

try:
    import websockets
except ImportError:
    print("Please install websockets: pip install websockets")
    sys.exit(1)


class InferenceClient:
    """
    WebSocket client for real-time video inference.
    """
    
    def __init__(
        self,
        server_url: str = "ws://localhost:8000/ws/video",
        source: Union[str, int] = 0,
        display: bool = True,
        benchmark: bool = False
    ):
        self.server_url = server_url
        self.source = source if source != "webcam" else 0
        self.display = display
        self.benchmark = benchmark
        self.running = False
        
        # Stats
        self.frames_sent = 0
        self.predictions_received = 0
        self.start_time: Optional[float] = None
        self.latencies: list = []

        # Display buffers (avoid race with async tasks)
        self._current_display_frame: Optional[np.ndarray] = None
        self._last_frame: Optional[np.ndarray] = None
        
    async def run(self):
        """Run the inference client."""
        self.running = True
        self.start_time = time.time()
        
        # Open video source
        cap = cv2.VideoCapture(self.source)
        if not cap.isOpened():
            print(f"Failed to open video source: {self.source}")
            return
        
        print(f"[Client] Connecting to {self.server_url}")
        
        try:
            async with websockets.connect(self.server_url) as ws:
                print("[Client] Connected!")
                
                # Create tasks for sending and receiving
                send_task = asyncio.create_task(self._send_frames(ws, cap))
                recv_task = asyncio.create_task(self._receive_predictions(ws))
                
                # Run until stopped
                await asyncio.gather(send_task, recv_task)
                
        except Exception as e:
            print(f"[Client] Connection error: {e}")
        finally:
            cap.release()
            if self.display:
                cv2.destroyAllWindows()
            self._print_stats()
    
    async def _send_frames(self, ws, cap: cv2.VideoCapture):
        """Send frames to server."""
        target_interval = 1.0 / 10  # ~10 FPS max send rate
        
        while self.running:
            frame_start = time.time()
            
            ret, frame = cap.read()
            if not ret:
                if isinstance(self.source, str):
                    # Video file ended
                    print("[Client] Video ended")
                    self.running = False
                    break
                continue
            
            # Encode frame as JPEG
            _, buffer = cv2.imencode('.jpg', frame, [cv2.IMWRITE_JPEG_QUALITY, 80])
            frame_bytes = buffer.tobytes()

            # Send to server
            try:
                await ws.send(frame_bytes)
                self.frames_sent += 1
            except Exception as e:
                print(f"[Client] Send error: {e}")
                self.running = False
                break
            
            # Store frame for display overlay
            self._last_frame = frame
            if (
                self._current_display_frame is None
                or self._current_display_frame.shape != frame.shape
            ):
                self._current_display_frame = frame.copy()

            # Display frame if enabled
            if self.display and self._current_display_frame is not None:
                cv2.imshow("TinyViT Inference", self._current_display_frame)
                if cv2.waitKey(1) & 0xFF in (ord('q'), 27):  # q or ESC
                    self.running = False
                    break
            
            # Rate limiting
            elapsed = time.time() - frame_start
            if elapsed < target_interval:
                await asyncio.sleep(target_interval - elapsed)
    
    async def _receive_predictions(self, ws):
        """Receive predictions from server."""
        if self._current_display_frame is None:
            self._current_display_frame = np.zeros((480, 640, 3), dtype=np.uint8)
        if self._last_frame is None:
            self._last_frame = self._current_display_frame.copy()
        
        while self.running:
            try:
                response = await asyncio.wait_for(ws.recv(), timeout=1.0)
                data = json.loads(response)
                
                if data.get("type") == "prediction":
                    self.predictions_received += 1
                    
                    # Update display frame with predictions
                    if self._last_frame is None:
                        continue
                    display_frame = self._last_frame.copy()
                    self._draw_predictions(display_frame, data)
                    self._current_display_frame = display_frame
                    
                    if self.benchmark:
                        # Record latency if we have timing info
                        server_fps = data.get("fps", 0)
                        print(f"\r[FPS] Server: {server_fps:.1f} | "
                              f"Frames: {self.frames_sent} | "
                              f"Predictions: {self.predictions_received}", end="")
                        
            except asyncio.TimeoutError:
                continue
            except Exception as e:
                if self.running:
                    print(f"[Client] Receive error: {e}")
                break
    
    def _draw_predictions(self, frame: np.ndarray, data: dict):
        """Draw prediction overlay on frame."""
        predictions = data.get("predictions", [])
        fps = data.get("fps", 0)
        
        # Draw background
        overlay_h = 30 + len(predictions) * 25
        cv2.rectangle(frame, (10, 10), (350, 10 + overlay_h), (0, 0, 0), -1)
        cv2.rectangle(frame, (10, 10), (350, 10 + overlay_h), (100, 100, 100), 1)
        
        # Draw FPS
        cv2.putText(frame, f"FPS: {fps:.1f}", (20, 30),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1)
        
        # Draw predictions
        y = 55
        for pred in predictions[:5]:
            label = pred.get("label", "unknown")
            conf = pred.get("confidence", 0)
            text = f"{label}: {conf*100:.1f}%"
            
            # Color based on confidence
            color = (0, int(255 * conf), int(255 * (1-conf)))
            cv2.putText(frame, text, (20, y),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.5, color, 1)
            y += 25
    
    def _print_stats(self):
        """Print final statistics."""
        if self.start_time is None:
            return
            
        duration = time.time() - self.start_time
        print(f"\n\n[Stats]")
        print(f"  Duration: {duration:.1f}s")
        print(f"  Frames sent: {self.frames_sent}")
        print(f"  Predictions received: {self.predictions_received}")
        print(f"  Average FPS: {self.frames_sent / duration:.1f}")


async def main():
    parser = argparse.ArgumentParser(description="TinyViT Inference Client")
    parser.add_argument(
        "--source",
        default="webcam",
        help="Video source: 'webcam', camera index (0, 1, ...), or video file path"
    )
    parser.add_argument(
        "--server",
        default="ws://localhost:8000/ws/video",
        help="WebSocket server URL"
    )
    parser.add_argument(
        "--no-display",
        action="store_true",
        help="Disable video display window"
    )
    parser.add_argument(
        "--benchmark",
        action="store_true",
        help="Enable benchmark mode (print FPS stats)"
    )
    
    args = parser.parse_args()
    
    # Parse source
    source = args.source
    if source == "webcam":
        source = 0
    elif source.isdigit():
        source = int(source)
    
    client = InferenceClient(
        server_url=args.server,
        source=source,
        display=not args.no_display,
        benchmark=args.benchmark
    )
    
    await client.run()


if __name__ == "__main__":
    asyncio.run(main())
