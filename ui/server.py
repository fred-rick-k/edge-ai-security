#!/usr/bin/env python3
"""
ui/server.py
============
Real-time Live VLM WebUI and Telemetry Server for NVIDIA Jetson Orin Nano Super.

Features:
  - Serves HTTPS WebUI on :8443 (with self-signed TLS) & HTTP redirect on :8091
  - MJPEG video streaming (/video_feed) from RTSP streams or synthetic camera feed
  - WebSocket telemetry streaming (/ws/telemetry) at 2Hz (500ms)
  - VLM inference proxy (/api/infer, /api/infer_stream) connected to local
    Cosmos-Reason2-2B on http://127.0.0.1:8090/v1/chat/completions
  - Health & status monitoring (/health, /api/status)
"""

import ast
import os
import re
import sys
import ssl
import time
import json
import base64
import asyncio
import logging
import argparse
import subprocess
from pathlib import Path
from typing import Optional, Dict, Any, List

import aiohttp
from aiohttp import web, WSMsgType
# Optional OpenCV / NumPy for camera capture
try:
    import cv2
    import numpy as np
    HAS_CV2 = True
except ImportError:
    HAS_CV2 = False

from jetson_telemetry import TelemetryCollector

# Logging setup
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger("live-vlm-webui")

# Paths
BASE_DIR = Path(__file__).resolve().parent
REPO_ROOT = BASE_DIR.parent
STATIC_DIR = BASE_DIR / "static"
CONFIG_DIR = REPO_ROOT / "config"
TLS_DIR = REPO_ROOT / "tls"
OPENSHELL_BIN = "/usr/bin/openshell"
OPENSHELL_USER = "jetson"          # owns ~/.config/openshell (gateway mTLS client certs)
OPENSHELL_SANDBOX = "camera-agent"
OPENSHELL_EVENTS_LINES = 50        # max gateway journal lines to fetch
OPENSHELL_LOG_FETCH = 600          # sandbox log lines requested (about 3 min; ~1/3 are CONFIG noise)
OPENSHELL_LOG_KEEP = 40            # newest non-CONFIG lines shown (plus every DENIED in the window)

# Session 3-6: "Test any URL" parameters
TESTURL_MAX_LEN = 2048             # reject URLs longer than this
TESTURL_RATE_WINDOW = 60           # seconds
TESTURL_RATE_LIMIT = 5             # max requests per IP per window
TESTURL_LOG_LINES = 40             # lines of sandbox log to scan for a matching DENIED entry
TESTURL_DENY_WINDOW_S = 12         # seconds after exec start within which to look for DENIED line

# Camera URL (Session 3-5j): config/camera.env is retired.  The RTSP URL is rendered by the edge
# vault-agent `template` stanza to a root-only tmpfs file and handed to this unit by systemd
# `LoadCredential=camera-rtsp-url:...` (drop-in installed by scripts/17-camera-credential.sh).
# It appears under $CREDENTIALS_DIRECTORY.  Without it (stage not run, or file missing) the URL
# is empty and the WebUI uses the synthetic test pattern.  The URL is never logged.
CAMERA_CREDENTIAL_ID = "camera-rtsp-url"


def _read_camera_url() -> str:
    cred_dir = os.environ.get("CREDENTIALS_DIRECTORY", "")
    if not cred_dir:
        return ""
    try:
        return (Path(cred_dir) / CAMERA_CREDENTIAL_ID).read_text().strip()
    except OSError:
        return ""


# Both selectable streams are the same single camera URL (as with the old camera.env).
RTSP_STREAM_1 = _read_camera_url()
RTSP_STREAM_2 = RTSP_STREAM_1
VLM_ENDPOINT = os.getenv("VLM_ENDPOINT", "http://127.0.0.1:8090/v1/chat/completions")
VLM_HEALTH_URL = os.getenv("VLM_HEALTH_URL", "http://127.0.0.1:8090/health")
VLM_MODEL = os.getenv("VLM_MODEL", "cosmos-reason2-2b")

# Session 5-5d (Bug 4): the WebUI default prompt is the agent's profile prompt, read from the one definition in
# agent/agent.py (_PROFILES[<profile>]["prompt"]).  Read with ast (agent.py is NOT imported: it needs the sandbox's
# requests/Pillow).  The profile name must match the sandbox's CAMERA_PROFILE (stage 3-5i default: indoor).
AGENT_SOURCE = REPO_ROOT / "agent" / "agent.py"
AGENT_PROFILE = os.getenv("CAMERA_PROFILE", "indoor")


def _read_agent_prompt() -> tuple:
    """Return (profile_name, prompt) from agent/agent.py.  Raises on any problem; there is no fallback text."""
    tree = ast.parse(AGENT_SOURCE.read_text(encoding="utf-8"))
    for node in tree.body:
        if isinstance(node, ast.AnnAssign):
            target, value = node.target, node.value
        elif isinstance(node, ast.Assign) and len(node.targets) == 1:
            target, value = node.targets[0], node.value
        else:
            continue
        if isinstance(target, ast.Name) and target.id == "_PROFILES":
            profiles = ast.literal_eval(value)
            name = AGENT_PROFILE if AGENT_PROFILE in profiles else "indoor"   # same fallback as agent._load_profile
            return name, profiles[name]["prompt"]
    raise RuntimeError("_PROFILES not found in agent/agent.py")


class VideoCaptureManager:
    """Manages RTSP stream ingestion with synthetic test pattern fallback."""

    def __init__(self):
        self.current_stream_url = RTSP_STREAM_1
        self.stream_index = 1
        self.cap = None
        self.latest_frame_jpeg: Optional[bytes] = None
        self.latest_frame_b64: Optional[str] = None
        self.running = False
        self._lock = asyncio.Lock()
        self.frame_count = 0
        self.is_synthetic = False

    def start(self):
        self.running = True
        self._open_stream()

    def stop(self):
        self.running = False
        if self.cap:
            try:
                self.cap.release()
            except Exception:
                pass
            self.cap = None

    def switch_stream(self, index: int):
        self.stream_index = index
        if index == 1:
            self.current_stream_url = RTSP_STREAM_1
        elif index == 2:
            self.current_stream_url = RTSP_STREAM_2
        else:
            self.current_stream_url = ""
        self._open_stream()

    def reconnect(self) -> dict:
        """Re-read the camera credential and re-attempt the RTSP connection.

        systemd copies the credential when the unit starts, so a URL changed in Vault reaches this
        process only after the unit restarts (the vault-agent template `exec` does that)."""
        global RTSP_STREAM_1, RTSP_STREAM_2
        RTSP_STREAM_1 = _read_camera_url()
        RTSP_STREAM_2 = RTSP_STREAM_1

        if self.stream_index == 1:
            self.current_stream_url = RTSP_STREAM_1
        elif self.stream_index == 2:
            self.current_stream_url = RTSP_STREAM_2
        else:
            self.current_stream_url = RTSP_STREAM_1
            self.stream_index = 1

        self._open_stream()
        return {
            "is_synthetic": self.is_synthetic,
            "stream_index": self.stream_index,
            "connected": not self.is_synthetic,
            "has_stream_url": bool(self.current_stream_url),
        }

    def _open_stream(self):
        if self.cap:
            try:
                self.cap.release()
            except Exception:
                pass
            self.cap = None

        if HAS_CV2 and self.current_stream_url:
            # Mask credentials in logs for security
            clean_url = re.sub(r"://([^:@]+):([^@]+)@", "://***:***@", self.current_stream_url)
            logger.info(f"Connecting to RTSP stream {self.stream_index}: {clean_url}")
            try:
                # Force TCP transport and minimal buffer for lowest latency live stream
                os.environ["OPENCV_FFMPEG_CAPTURE_OPTIONS"] = "rtsp_transport;tcp"
                self.cap = cv2.VideoCapture(self.current_stream_url, cv2.CAP_FFMPEG)
                self.cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
                if self.cap.isOpened():
                    ret, test_frame = self.cap.read()
                    if ret and test_frame is not None:
                        self.is_synthetic = False
                        logger.info(f"RTSP stream {self.stream_index} connected and receiving live frames.")
                        return
                    else:
                        logger.warning(f"RTSP stream {self.stream_index} opened but failed to read initial frame.")
            except Exception as e:
                logger.warning(f"RTSP connection failed: {e}")

        self.is_synthetic = True
        logger.info("Using synthetic security camera video generator.")

    def get_latest_frame_jpeg(self) -> bytes:
        if self.latest_frame_jpeg:
            return self.latest_frame_jpeg
        return self._generate_synthetic_frame()

    def get_latest_frame_b64(self) -> str:
        if self.latest_frame_b64:
            return self.latest_frame_b64
        jpeg = self.get_latest_frame_jpeg()
        return base64.b64encode(jpeg).decode("utf-8")

    async def capture_loop(self):
        """Background frame acquisition loop (runs at ~15-20 FPS)."""
        while self.running:
            try:
                frame_bytes = None
                if not self.is_synthetic and self.cap and self.cap.isOpened():
                    ret, frame = self.cap.read()
                    if ret and frame is not None:
                        # Resize if too large for edge display
                        h, w = frame.shape[:2]
                        if w > 1280:
                            frame = cv2.resize(frame, (1280, int(h * 1280 / w)))
                        # Encode to JPEG
                        _, buffer = cv2.imencode('.jpg', frame, [int(cv2.IMWRITE_JPEG_QUALITY), 80])
                        frame_bytes = buffer.tobytes()
                    else:
                        logger.warning("RTSP stream lost frame, switching to synthetic fallback...")
                        self.is_synthetic = True

                if frame_bytes is None:
                    frame_bytes = self._generate_synthetic_frame()

                self.latest_frame_jpeg = frame_bytes
                self.latest_frame_b64 = base64.b64encode(frame_bytes).decode("utf-8")
                self.frame_count += 1

            except Exception as e:
                logger.error(f"Error in video capture loop: {e}")

            await asyncio.sleep(0.06)  # ~16 FPS

    def _generate_synthetic_frame(self) -> bytes:
        """Generates an animated test security camera scene with timestamps and objects."""
        if not HAS_CV2:
            return b""

        w, h = 960, 540
        # Background: Suburban driveway / entrance simulation
        img = np.zeros((h, w, 3), dtype=np.uint8)
        img[:] = (35, 45, 50)  # dark slate asphalt

        # Driveway area
        pts_driveway = np.array([[200, h], [400, 220], [560, 220], [760, h]], np.int32)
        cv2.fillPoly(img, [pts_driveway], (60, 65, 70))

        # House & Garage Wall
        cv2.rectangle(img, (150, 100), (810, 220), (120, 110, 105), -1)
        # Garage Door (closed / open animation state)
        garage_state = "CLOSED"
        cv2.rectangle(img, (280, 130), (520, 220), (180, 175, 170), -1)
        for y in range(150, 220, 20):
            cv2.line(img, (280, y), (520, y), (130, 125, 120), 2)
        cv2.putText(img, f"GARAGE: {garage_state}", (310, 180), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (40, 40, 40), 2)

        # Front Gate
        cv2.rectangle(img, (580, 140), (700, 220), (80, 90, 110), -1)
        cv2.putText(img, "GATE: CLOSED", (590, 180), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (220, 220, 220), 1)

        # Simulated Moving Object / Package / Person based on frame count
        t = (self.frame_count % 300) / 300.0
        obj_x = int(320 + np.sin(t * 2 * np.pi) * 120)
        obj_y = int(320 + np.cos(t * 2 * np.pi) * 30)

        # Draw a simulated delivery package / box on driveway
        cv2.rectangle(img, (obj_x, obj_y), (obj_x + 50, obj_y + 40), (45, 120, 180), -1)
        cv2.rectangle(img, (obj_x, obj_y), (obj_x + 50, obj_y + 40), (20, 80, 140), 2)
        cv2.putText(img, "PACKAGE", (obj_x - 5, obj_y - 8), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (50, 220, 100), 1)

        # HUD / Camera Overlay
        now_str = time.strftime("%Y-%m-%d %H:%M:%S")
        cv2.putText(img, f"CAM-01 [FRONT_YARD_DRIVEWAY] - {now_str}", (20, 35),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.65, (0, 255, 120), 2)
        cv2.putText(img, "STREAM: SYNTHETIC SIMULATOR (1080p@15fps)", (20, 65),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.45, (180, 180, 180), 1)
        cv2.putText(img, "JETSON ORIN NANO EDGE SECURITY", (w - 320, 35),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 220, 255), 1)

        # Timestamp box
        cv2.putText(img, f"FRAME: {self.frame_count:06d}", (20, h - 20),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.45, (200, 200, 200), 1)

        _, buffer = cv2.imencode('.jpg', img, [int(cv2.IMWRITE_JPEG_QUALITY), 80])
        return buffer.tobytes()


# Global singletons
telemetry = TelemetryCollector(sample_interval=0.5)
video_manager = VideoCaptureManager()
active_ws_clients: List[web.WebSocketResponse] = []


# ── HTTP Handlers ─────────────────────────────────────────────────────────────

async def handle_index(request: web.Request) -> web.Response:
    index_file = STATIC_DIR / "index.html"
    if index_file.exists():
        return web.FileResponse(index_file)
    return web.Response(text="Live VLM WebUI loading...", content_type="text/html")


async def handle_health(request: web.Request) -> web.Response:
    """Health endpoint for systemd and monitoring."""
    return web.json_response({
        "status": "ok",
        "service": "live-vlm-webui",
        "timestamp": time.time(),
        "video_frames": video_manager.frame_count,
        "is_synthetic_camera": video_manager.is_synthetic,
    })


async def handle_api_reconnect_camera(request: web.Request) -> web.Response:
    """Forces re-reading the camera credential and re-attempting the RTSP connection."""
    res = video_manager.reconnect()
    return web.json_response(res)


async def handle_api_status(request: web.Request) -> web.Response:
    """Detailed status endpoint."""
    vlm_healthy = False
    try:
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=2.0)) as session:
            async with session.get(VLM_HEALTH_URL) as resp:
                vlm_healthy = (resp.status == 200)
    except Exception:
        vlm_healthy = False

    return web.json_response({
        "vlm_server": {
            "endpoint": VLM_ENDPOINT,
            "model": VLM_MODEL,
            "healthy": vlm_healthy,
        },
        "camera": {
            "stream_index": video_manager.stream_index,
            "is_synthetic": video_manager.is_synthetic,
            "frame_count": video_manager.frame_count,
        },
        "telemetry_source": telemetry.get_snapshot().get("source", "unknown"),
    })


async def handle_video_feed(request: web.Request) -> web.StreamResponse:
    """Multipart MJPEG video stream."""
    response = web.StreamResponse(
        status=200,
        reason='OK',
        headers={
            'Content-Type': 'multipart/x-mixed-replace; boundary=frame',
            'Cache-Control': 'no-cache',
            'Connection': 'close',
            'Pragma': 'no-cache'
        }
    )
    await response.prepare(request)

    try:
        while True:
            frame_bytes = video_manager.get_latest_frame_jpeg()
            header = (
                b'--frame\r\n'
                b'Content-Type: image/jpeg\r\n'
                b'Content-Length: ' + str(len(frame_bytes)).encode() + b'\r\n\r\n'
            )
            await response.write(header + frame_bytes + b'\r\n')
            await asyncio.sleep(0.066)  # ~15 FPS
    except (asyncio.CancelledError, ConnectionResetError):
        pass
    return response


async def handle_capture_frame(request: web.Request) -> web.Response:
    """Returns the current camera frame as JPEG image or JSON with Base64."""
    format_type = request.query.get("format", "jpeg")
    if format_type == "json":
        return web.json_response({
            "image_b64": video_manager.get_latest_frame_b64(),
            "timestamp": time.time(),
            "frame_id": video_manager.frame_count,
        })
    else:
        frame_bytes = video_manager.get_latest_frame_jpeg()
        return web.Response(body=frame_bytes, content_type="image/jpeg")


async def handle_api_telemetry(request: web.Request) -> web.Response:
    """REST endpoint for single telemetry snapshot."""
    return web.json_response(telemetry.get_snapshot())


async def handle_ws_telemetry(request: web.Request) -> web.WebSocketResponse:
    """WebSocket stream emitting telemetry at 2Hz."""
    ws = web.WebSocketResponse()
    await ws.prepare(request)
    active_ws_clients.append(ws)
    logger.info(f"WebSocket telemetry client connected (total: {len(active_ws_clients)})")

    try:
        async for msg in ws:
            if msg.type == WSMsgType.TEXT:
                if msg.data == "ping":
                    await ws.send_str("pong")
            elif msg.type == WSMsgType.ERROR:
                logger.debug(f"WS error: {ws.exception()}")
    finally:
        if ws in active_ws_clients:
            active_ws_clients.remove(ws)
        logger.info(f"WebSocket telemetry client disconnected (total: {len(active_ws_clients)})")

    return ws


async def handle_api_infer(request: web.Request) -> web.Response:
    """
    Proxies multimodal prompt + current frame to local VLM.
    Body JSON:
      {
        "prompt": "Describe this scene...",
        "image_b64": "<optional base64 image; defaults to current frame>",
        "temperature": 0.0,
        "max_tokens": 512
      }
    """
    try:
        data = await request.json()
    except Exception:
        data = {}

    prompt = data.get("prompt", "Describe what is happening in this camera frame. Check for people, packages, open gates or open garage doors.")
    image_b64 = data.get("image_b64") or video_manager.get_latest_frame_b64()
    temperature = float(data.get("temperature", 0.0))
    max_tokens = int(data.get("max_tokens", 512))

    payload = {
        "model": VLM_MODEL,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{image_b64}"}},
                {"type": "text", "text": prompt}
            ]
        }],
        "temperature": temperature,
        "max_tokens": max_tokens,
    }

    t0 = time.perf_counter()
    try:
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=120.0)) as session:
            async with session.post(VLM_ENDPOINT, json=payload) as resp:
                if resp.status != 200:
                    err_text = await resp.text()
                    logger.error(f"VLM server error HTTP {resp.status}: {err_text}")
                    return web.json_response({
                        "error": f"VLM server returned HTTP {resp.status}",
                        "details": err_text[:300]
                    }, status=502)

                res_json = await resp.json()

        latency_s = round(time.perf_counter() - t0, 3)
        choice = res_json.get("choices", [{}])[0].get("message", {})
        content = choice.get("content", "").strip()
        usage = res_json.get("usage", {})

        return web.json_response({
            "content": content,
            "latency_seconds": latency_s,
            "usage": usage,
            "prompt": prompt,
            "model": VLM_MODEL,
        })

    except asyncio.TimeoutError:
        return web.json_response({"error": "VLM server timed out (120s limit)"}, status=504)
    except Exception as e:
        logger.error(f"Inference exception: {e}")
        return web.json_response({"error": str(e)}, status=500)


async def handle_api_default_prompt(request: web.Request) -> web.Response:
    """Read-only: the agent's profile prompt, the WebUI's default prompt (Session 5-5d)."""
    try:
        profile, prompt = _read_agent_prompt()
    except Exception as e:
        logger.error(f"default prompt unavailable: {e}")
        return web.json_response({"error": "default prompt unavailable"}, status=500)
    return web.json_response({"profile": profile, "prompt": prompt})


async def handle_api_infer_stream(request: web.Request) -> web.StreamResponse:
    """Server-Sent Events (SSE) streaming for live token display."""
    try:
        data = await request.json()
    except Exception:
        data = {}

    prompt = data.get("prompt", "Describe what is happening in this camera frame.")
    image_b64 = data.get("image_b64") or video_manager.get_latest_frame_b64()
    temperature = float(data.get("temperature", 0.0))
    max_tokens = int(data.get("max_tokens", 512))

    payload = {
        "model": VLM_MODEL,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{image_b64}"}},
                {"type": "text", "text": prompt}
            ]
        }],
        "temperature": temperature,
        "max_tokens": max_tokens,
        "stream": True,
    }

    response = web.StreamResponse(
        status=200,
        headers={
            'Content-Type': 'text/event-stream',
            'Cache-Control': 'no-cache',
            'Connection': 'keep-alive',
            'Access-Control-Allow-Origin': '*',
        }
    )
    await response.prepare(request)

    t0 = time.perf_counter()
    first_token_time = None
    token_count = 0

    try:
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=180.0)) as session:
            async with session.post(VLM_ENDPOINT, json=payload) as resp:
                if resp.status != 200:
                    err_msg = json.dumps({"error": f"VLM returned HTTP {resp.status}"})
                    await response.write(f"data: {err_msg}\n\n".encode("utf-8"))
                    return response

                async for line in resp.content:
                    line_str = line.decode("utf-8").strip()
                    if not line_str or line_str.startswith(":"):
                        continue
                    if line_str.startswith("data: "):
                        data_part = line_str[6:]
                        if data_part == "[DONE]":
                            total_time = round(time.perf_counter() - t0, 3)
                            ttft_ms = round((first_token_time - t0) * 1000, 1) if first_token_time else 0
                            tps = round(token_count / total_time, 1) if total_time > 0 else 0
                            done_meta = json.dumps({
                                "done": True,
                                "total_time": total_time,
                                "ttft_ms": ttft_ms,
                                "tokens": token_count,
                                "tokens_per_sec": tps
                            })
                            await response.write(f"data: {done_meta}\n\n".encode("utf-8"))
                            break

                        try:
                            chunk = json.loads(data_part)
                            delta = chunk.get("choices", [{}])[0].get("delta", {})
                            content_delta = delta.get("content", "")

                            if content_delta:
                                if first_token_time is None:
                                    first_token_time = time.perf_counter()
                                token_count += 1

                            evt = json.dumps({
                                "delta": content_delta,
                            })
                            await response.write(f"data: {evt}\n\n".encode("utf-8"))
                        except Exception:
                            pass

    except Exception as e:
        logger.error(f"Stream exception: {e}")
        err_msg = json.dumps({"error": str(e)})
        await response.write(f"data: {err_msg}\n\n".encode("utf-8"))

    return response


# ── Background Telemetry Broadcast Loop ──────────────────────────────────────

async def telemetry_broadcast_loop():
    """Pushes telemetry snapshots to all connected WebSockets at 2Hz."""
    while True:
        try:
            if active_ws_clients:
                snap = telemetry.get_snapshot()
                msg = json.dumps(snap)
                dead_clients = []
                for ws in active_ws_clients:
                    try:
                        await ws.send_str(msg)
                    except Exception:
                        dead_clients.append(ws)
                for dws in dead_clients:
                    if dws in active_ws_clients:
                        active_ws_clients.remove(dws)
        except Exception as e:
            logger.debug(f"Telemetry broadcast error: {e}")

        await asyncio.sleep(0.5)  # 2Hz (500ms)


# ── OpenShell Sandbox read-only API endpoints ────────────────────────────────
# Session 3-5j: the cards show the REAL state of the running `camera-agent` sandbox, read through the
# `openshell` CLI (documented read-only commands).  No policy file is parsed, no log file is tailed
# and nothing here writes to any log.  If the CLI fails inside this service, the error is shown as-is.

async def _run_openshell(*args: str, timeout: float = 8.0) -> tuple:
    """Run `openshell <args>` as the service user; return (returncode, stdout, stderr-or-error).

    `timeout` (seconds) is passed to asyncio.wait_for; callers that wrap a curl with
    --max-time 8 should use a slightly higher value (e.g. 15).
    """
    import pwd
    try:
        pw = pwd.getpwnam(OPENSHELL_USER)
        home, uid = pw.pw_dir, pw.pw_uid
    except KeyError:
        home, uid = os.environ.get("HOME", "/"), os.getuid()
    env = {**os.environ, "HOME": home, "XDG_RUNTIME_DIR": f"/run/user/{uid}"}
    try:
        proc = await asyncio.create_subprocess_exec(
            OPENSHELL_BIN, *args, env=env,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
        out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        try:
            proc.kill()
        except Exception:
            pass
        return 124, "", f"openshell {' '.join(args[:3])}: timed out after {timeout} s"
    except Exception as exc:
        return 127, "", f"openshell {' '.join(args[:3])}: {exc}"
    return (
        proc.returncode,
        out.decode("utf-8", "replace"),
        err.decode("utf-8", "replace").strip() or f"openshell exited {proc.returncode}",
    )


async def handle_openshell_policy(request: web.Request) -> web.Response:
    """GET /api/openshell/policy — effective policy of the camera-agent sandbox.

    Source: `openshell policy get camera-agent --full -o json` (shape measured on the device,
    2026-10-18): top-level hash/status/version/config_revision and `policy` with
    filesystem_policy, landlock, process and network_policies (provider-derived `_provider_*`).
    """
    rc, out, err = await _run_openshell("policy", "get", OPENSHELL_SANDBOX, "--full", "-o", "json")
    if rc != 0:
        return web.json_response({"ok": False, "error": err, "data": None}, status=200)
    try:
        doc = json.loads(out)
        pol = doc.get("policy") or {}
        fs = pol.get("filesystem_policy") or {}
        net = []
        for key, entry in (pol.get("network_policies") or {}).items():
            binaries = [b.get("path", "") for b in entry.get("binaries", [])]
            for ep in entry.get("endpoints", []):
                net.append({
                    "policy": entry.get("name", key),
                    "host": ep.get("host", ""),
                    "port": ep.get("port", ""),
                    "protocol": ep.get("protocol", ""),
                    "enforcement": ep.get("enforcement", ""),
                    "rules": [
                        f"{r['allow'].get('method', '*')} {r['allow'].get('path', '*')}"
                        for r in ep.get("rules", []) if "allow" in r
                    ],
                    "binaries": binaries,
                })
        data = {
            "sandbox": doc.get("sandbox", OPENSHELL_SANDBOX),
            "status": doc.get("status", ""),
            "version": doc.get("version"),
            "hash": doc.get("hash", ""),
            "landlock": (pol.get("landlock") or {}).get("compatibility", ""),
            "process": pol.get("process") or {},
            "fs_read_only": fs.get("read_only", []),
            "fs_read_write": fs.get("read_write", []),
            "include_workdir": fs.get("include_workdir"),
            "network": net,
        }
    except (ValueError, AttributeError, KeyError, TypeError) as exc:
        logger.warning("openshell policy parse error: %s", exc)
        return web.json_response({"ok": False, "error": f"cannot parse policy JSON: {exc}", "data": None})

    # Providers: names, types and credential KEY NAMES only (`provider list -o json` carries no values).
    prc, pout, perr = await _run_openshell("provider", "list", "-o", "json")
    providers, perror = [], ""
    if prc == 0:
        try:
            providers = [
                {"name": p.get("name", ""), "type": p.get("type", ""),
                 "credential_keys": p.get("credential_keys", [])}
                for p in json.loads(pout).get("providers", [])
            ]
        except (ValueError, AttributeError, TypeError) as exc:
            perror = f"cannot parse provider list: {exc}"
    else:
        perror = f"provider list failed: {perr}"
    data["providers"] = providers
    data["providers_error"] = perror
    return web.json_response({"ok": True, "data": data})


async def handle_openshell_events(request: web.Request) -> web.Response:
    """GET /api/openshell/events — gateway status + recent journal lines.

    Also checks `systemctl --user is-active` so the UI can show a live
    UP/DOWN badge independently of what the journal tail happens to contain.
    """
    # systemctl --user and journalctl --user-unit both need XDG_RUNTIME_DIR to
    # reach the user's D-Bus socket. The WebUI runs as a systemd system service
    # so the var is not set in its environment — build it explicitly.
    import pwd
    try:
        uid = pwd.getpwnam("jetson").pw_uid
    except KeyError:
        uid = os.getuid()
    user_env = {**os.environ, "XDG_RUNTIME_DIR": f"/run/user/{uid}"}

    # Check live gateway status.
    try:
        status_result = subprocess.run(
            ["systemctl", "--user", "is-active", "openshell-gateway.service"],
            capture_output=True, text=True, timeout=3, env=user_env,
        )
        gateway_active = status_result.stdout.strip() == "active"
    except Exception:
        gateway_active = False

    # Fetch journal — only lines since the most recent start to avoid showing
    # stop/restart noise from previous bootstrap sessions.
    # journalctl --user-unit also needs XDG_RUNTIME_DIR.
    try:
        result = subprocess.run(
            [
                "journalctl",
                "--user-unit=openshell-gateway.service",
                "--no-pager",
                "-n", str(OPENSHELL_EVENTS_LINES),
                "--output=short-iso",
            ],
            capture_output=True,
            text=True,
            timeout=5,
            env=user_env,
        )
        all_lines = [l for l in result.stdout.splitlines()
                     if l.strip() and not l.strip().startswith("-- No entries")]

        # Find the index of the last "Starting …" line so we only show
        # the current boot cycle, not historical stop/restart churn.
        last_start = -1
        for i, l in enumerate(all_lines):
            if "Starting openshell-gateway" in l:
                last_start = i
        lines = all_lines[last_start:] if last_start >= 0 else all_lines

    except Exception as exc:
        logger.warning("openshell events journal read error: %s", exc)
        lines = []

    return web.json_response({"ok": True, "gateway_active": gateway_active, "lines": lines})


async def handle_openshell_audit(request: web.Request) -> web.Response:
    """GET /api/openshell/audit — real sandbox OCSF log of the camera-agent sandbox.

    Source: `openshell logs camera-agent --source sandbox -n N` (the supervisor's own log; nothing
    in this repo writes to it).  The per-second CONFIG:* bookkeeping lines are dropped.  Every
    DENIED line in the window is kept; the rest is cut to the newest OPENSHELL_LOG_KEEP lines.
    """
    rc, out, err = await _run_openshell(
        "logs", OPENSHELL_SANDBOX, "--source", "sandbox", "-n", str(OPENSHELL_LOG_FETCH)
    )
    if rc != 0:
        return web.json_response({"ok": False, "error": err, "lines": [], "denied": 0}, status=200)

    lines = [l for l in out.splitlines() if l.strip() and " CONFIG:" not in l]
    denied_idx = [i for i, l in enumerate(lines) if " DENIED " in l]
    keep = set(range(max(0, len(lines) - OPENSHELL_LOG_KEEP), len(lines)))
    keep.update(denied_idx[-OPENSHELL_LOG_KEEP:])
    shown = [lines[i] for i in sorted(keep)]
    return web.json_response({
        "ok": True,
        "sandbox": OPENSHELL_SANDBOX,
        "window_lines": len(lines),
        "denied": len(denied_idx),
        "lines": shown,
    })


# ── "Test any URL" endpoint (Session 3-6) ────────────────────────────────────
# Rate-limit table: {peer_ip: [timestamp, ...]}
_testurl_rate: Dict[str, List[float]] = {}


async def handle_openshell_test_url(request: web.Request) -> web.Response:
    """POST /api/openshell/test-url  {url: <string>}

    Runs `openshell sandbox exec camera-agent -- /usr/bin/python3 -c <probe> <URL>`
    **as an argument list** (never a shell string; the URL is a single argv element,
    never interpolated). Uses python3 (the agent's binary, already allowed by the
    provider policy rules) rather than curl (not in the policy binaries list).
    Then reads the sandbox log and looks for a DENIED line within TESTURL_DENY_WINDOW_S
    seconds of the exec start.

    Security properties:
    - URL validated to ^https?:// and max length before reaching subprocess.
    - argv built as a Python list; subprocess never sees a shell string.
    - Rate-limited: TESTURL_RATE_LIMIT requests per IP per TESTURL_RATE_WINDOW seconds.
    - This endpoint cannot change sandbox policy or reach outside the sandbox.
    """
    # ── Rate limit ──────────────────────────────────────────────────────────
    peer = request.remote or "unknown"
    now = time.monotonic()
    bucket = _testurl_rate.setdefault(peer, [])
    # Evict old entries
    _testurl_rate[peer] = [t for t in bucket if now - t < TESTURL_RATE_WINDOW]
    if len(_testurl_rate[peer]) >= TESTURL_RATE_LIMIT:
        return web.json_response(
            {"ok": False, "error": f"Rate limit: max {TESTURL_RATE_LIMIT} tests per {TESTURL_RATE_WINDOW} s"},
            status=429,
        )
    _testurl_rate[peer].append(now)

    # ── Parse and validate URL ───────────────────────────────────────────────
    try:
        body = await request.json()
    except Exception:
        return web.json_response({"ok": False, "error": "invalid JSON body"}, status=400)

    url = str(body.get("url", "")).strip()
    if not url:
        return web.json_response({"ok": False, "error": "url field is required"}, status=400)
    if len(url) > TESTURL_MAX_LEN:
        return web.json_response({"ok": False, "error": f"url too long (max {TESTURL_MAX_LEN} chars)"}, status=400)
    # Only http and https are permitted — never file://, ftp://, etc.
    if not re.match(r'^https?://', url, re.IGNORECASE):
        return web.json_response({"ok": False, "error": "only http:// and https:// URLs are supported"}, status=400)

    exec_start = time.monotonic()
    logger.info("test-url: running exec in sandbox for scheme+host part (URL not logged)")

    # ── Run the probe inside the sandbox ─────────────────────────────────────
    # We use python3 (already the agent binary and covered by the provider rules'
    # binaries list) rather than curl (not in the policy binaries list).
    # The URL is passed as a positional argument, never shell-split.
    # argv layout: python3 -c <code> <url>  =>  sys.argv = ['-c', <url>]
    # Timeout: 8 s for the HTTP request; 15 s overall for openshell overhead.
    py_probe = (
        "import sys,urllib.request,urllib.error,ssl;"
        "ctx=ssl.create_default_context();"
        "ctx.check_hostname=False;ctx.verify_mode=ssl.CERT_NONE;"
        "req=urllib.request.Request(sys.argv[1],headers={'User-Agent':'OpenShell-probe/1.0'});"
        "code='000'\n"
        "try:\n"
        " r=urllib.request.urlopen(req,timeout=8,context=ctx);code=str(r.getcode())\n"
        "except urllib.error.HTTPError as e:code=str(e.code)\n"
        "except Exception:pass\n"
        "print(code,end='')"
    )
    rc, curl_out, curl_err = await _run_openshell(
        "sandbox", "exec", OPENSHELL_SANDBOX, "--",
        "/usr/bin/python3", "-c", py_probe, url,
        timeout=15.0,
    )
    http_code = curl_out.strip() if curl_out.strip().isdigit() else ""

    # ── Verdict: derived from evidence only ──────────────────────────────────
    # ALLOWED  = the probe received a real HTTP status (digit, not "000").
    # BLOCKED  = the supervisor logged a DENIED line for THIS host, stamped at/after exec start.
    # otherwise INCONCLUSIVE (never guessed as ALLOWED). Measured 2026-10-18: the probe
    # swallows connection errors and exits 0 with "000", and the supervisor's DENIED line can
    # reach `openshell logs` a moment after exec returns, so one early log read returned a
    # false ALLOWED for evil.com.
    from urllib.parse import urlsplit
    try:
        host = (urlsplit(url).hostname or "").lower()
    except ValueError:
        host = ""
    exec_wall = time.time() - (time.monotonic() - exec_start)
    deny_line = ""

    async def _find_deny() -> str:
        _, log_out, _ = await _run_openshell(
            "logs", OPENSHELL_SANDBOX, "--source", "sandbox", "-n", str(TESTURL_LOG_LINES),
        )
        for ll in reversed(log_out.splitlines()):
            if " DENIED " not in ll or not host or f" -> {host}:" not in ll.lower():
                continue
            em = re.match(r'^\[(\d+(?:\.\d+)?)\]', ll)
            if em and float(em.group(1)) >= exec_wall:
                return ll
        return ""

    real_response = http_code not in ("", "000")
    if real_response:
        verdict = "ALLOWED"
    else:
        # No HTTP response: poll the log briefly for the matching DENIED line.
        for attempt in range(4):
            deny_line = await _find_deny()
            if deny_line:
                break
            await asyncio.sleep(1.0)
        verdict = "BLOCKED" if deny_line else "INCONCLUSIVE"

    return web.json_response({
        "ok": True,
        "verdict": verdict,
        "http_code": http_code,
        "curl_exit": rc,
        "deny_log_line": deny_line,
    })


# ── Vault-backed widgets (Session 5-3b) ──────────────────────────────────────
# Three Tab-1 widgets, all backed by live Vault / trusted-edge data:
#   /api/vault/identity            lookup-self of the edge token (via trusted-edge) and gateway token (read here)
#   /api/vault/db-credential       trusted-edge GET  /admin/credential      (username, lease ttl, lease id; NO password)
#   /api/vault/rotate-credential   trusted-edge POST /admin/rotate-credential
#   /api/vault/events              trusted-edge GET  /admin/events          (CIPHERTEXT rows only)
#   /api/vault/manual-event        trusted-edge POST /admin/events          (Session 5-5c: store a manual inference)
#   /api/vault/decrypt             AppRole `control-plane-reader` -> Transit decrypt of the row's datakey,
#                                  AES-256-GCM decrypt of raw_payload in this process
# Secrets arrive as systemd credentials ($CREDENTIALS_DIRECTORY): `admin-key` (X-Admin-Key for trusted-edge)
# and `control-reader` (JSON role_id + secret_id).  Tokens, keys, DEKs and plaintext payloads are never logged.
# The WebUI itself is unauthenticated on the LAN (THREAT_MODEL T-13): anyone who can reach :8443 can use these.

MAC_IP = os.getenv("MAC_IP", "127.0.0.1")
MAC_USER = os.getenv("MAC_USER", "m")
VAULT_PORT = os.getenv("VAULT_PORT", "8200")
TRUSTED_EDGE_PORT = os.getenv("TRUSTED_EDGE_PORT", "8095")
JETSON_HOSTNAME = os.getenv("JETSON_HOSTNAME", "jetson.localdomain")

VAULT_ADDR = os.getenv("VAULT_ADDR", f"https://{MAC_IP}:{VAULT_PORT}").rstrip("/")
VAULT_CACERT = os.getenv("VAULT_CACERT", str(TLS_DIR / "vault.crt"))
TRUSTED_EDGE_URL = os.getenv("TRUSTED_EDGE_URL", f"http://{JETSON_HOSTNAME}:{TRUSTED_EDGE_PORT}").rstrip("/")
GATEWAY_TOKEN_FILE = "/run/openshell/vault-token"          # 0640 root:jetson (stage 5-1b)
ADMIN_KEY_CREDENTIAL_ID = "admin-key"
CONTROL_READER_CREDENTIAL_ID = "control-reader"
TRANSIT_MOUNT = "edge-ai-demo-encryption-transit"
TRANSIT_KEY = "edge-telemetry"
VAULT_HTTP_TIMEOUT = 10.0
ROTATE_TIMEOUT = 40.0
DECRYPT_MAX_CHARS = 256 * 1024
_vault_ssl_ctx: Optional[ssl.SSLContext] = None
_reader_token: Dict[str, Any] = {"token": "", "expires": 0.0}      # short-lived AppRole token (<= 5 min)


def _read_credential(name: str) -> str:
    cred_dir = os.environ.get("CREDENTIALS_DIRECTORY", "")
    if not cred_dir:
        return ""
    try:
        return (Path(cred_dir) / name).read_text().strip()
    except OSError:
        return ""


def _vault_ssl() -> ssl.SSLContext:
    global _vault_ssl_ctx
    if _vault_ssl_ctx is None:
        _vault_ssl_ctx = ssl.create_default_context(cafile=VAULT_CACERT)
    return _vault_ssl_ctx


async def _vault_call(method: str, path: str, token: str = "", body: Optional[dict] = None):
    """Vault HTTP API call over TLS pinned to tls/vault.crt.  Returns (status, json-or-{})."""
    headers = {"X-Vault-Token": token} if token else {}
    async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=VAULT_HTTP_TIMEOUT)) as session:
        async with session.request(method, f"{VAULT_ADDR}/v1/{path}", headers=headers,
                                   json=body, ssl=_vault_ssl()) as resp:
            try:
                data = await resp.json(content_type=None)
            except Exception:  # noqa: BLE001
                data = {}
            return resp.status, data if isinstance(data, dict) else {}


async def _edge_call(method: str, path: str, timeout: float = VAULT_HTTP_TIMEOUT, body: Optional[dict] = None):
    """trusted-edge admin call.  Returns (status, json-or-{}).  Raises RuntimeError if the admin key is missing."""
    key = _read_credential(ADMIN_KEY_CREDENTIAL_ID)
    if not key:
        raise RuntimeError("admin-key credential not delivered to this process")
    async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=timeout)) as session:
        async with session.request(method, f"{TRUSTED_EDGE_URL}{path}", headers={"X-Admin-Key": key},
                                   json=body) as resp:
            try:
                data = await resp.json(content_type=None)
            except Exception:  # noqa: BLE001
                data = {}
            return resp.status, data if isinstance(data, dict) else {}


def _identity_view(d: dict) -> dict:
    # Whitelist: the token id/accessor is never forwarded.
    return {k: d.get(k) for k in ("display_name", "policies", "ttl", "expire_time", "path")}


async def _identity_edge() -> dict:
    try:
        status, data = await _edge_call("GET", "/admin/identity")
    except RuntimeError:
        return {"error": "unavailable", "detail": "admin-key credential not delivered"}
    except Exception as exc:  # noqa: BLE001
        return {"error": "unavailable", "detail": type(exc).__name__}
    if status != 200:
        return {"error": "unavailable", "detail": f"trusted-edge HTTP {status}"}
    return _identity_view(data)


async def _identity_gateway() -> dict:
    try:
        token = Path(GATEWAY_TOKEN_FILE).read_text().strip()
    except PermissionError:
        return {"error": "unreadable"}
    except OSError as exc:
        return {"error": "unavailable", "detail": type(exc).__name__}
    if not token:
        return {"error": "unavailable", "detail": "token file empty"}
    try:
        status, data = await _vault_call("GET", "auth/token/lookup-self", token=token)
    except Exception as exc:  # noqa: BLE001
        return {"error": "unavailable", "detail": type(exc).__name__}
    finally:
        del token
    if status != 200:
        return {"error": "unavailable", "detail": f"vault HTTP {status}"}
    return _identity_view(data.get("data", {}))


async def handle_vault_identity(request: web.Request) -> web.Response:
    edge, gateway = await asyncio.gather(_identity_edge(), _identity_gateway())
    return web.json_response({"edge": edge, "gateway": gateway, "fetched_at": time.time()})


async def _edge_proxy(method: str, path: str, keys: Optional[tuple] = None,
                      timeout: float = VAULT_HTTP_TIMEOUT) -> web.Response:
    try:
        status, data = await _edge_call(method, path, timeout=timeout)
    except RuntimeError as exc:
        return web.json_response({"error": str(exc)}, status=503)
    except Exception as exc:  # noqa: BLE001
        return web.json_response({"error": f"trusted-edge unreachable ({type(exc).__name__})"}, status=502)
    if keys is not None and status == 200:
        data = {k: data.get(k) for k in keys}
    return web.json_response(data, status=status)


async def handle_vault_db_credential(request: web.Request) -> web.Response:
    return await _edge_proxy("GET", "/admin/credential",
                             keys=("db_username", "lease_ttl_s", "lease_duration_s", "lease_id", "rows_written"))


async def handle_vault_rotate_credential(request: web.Request) -> web.Response:
    logger.info("vault: rotate-credential requested from %s", request.remote)
    return await _edge_proxy("POST", "/admin/rotate-credential", timeout=ROTATE_TIMEOUT)


MANUAL_EVENT_MAX_CHARS = 8000        # = trusted-edge MAX_PAYLOAD_CHARS


async def handle_vault_manual_event(request: web.Request) -> web.Response:
    """POST /api/vault/manual-event {"text": "..."} — stores the text of a MANUAL WebUI inference (Session 5-5c).

    The WebUI holds no DB credential and no DEK: it forwards the text to trusted-edge POST /admin/events
    (X-Admin-Key), which encrypts it with the Transit DEK and INSERTs it as event_type=manual_inference.
    Like every /api/vault/* route this one is unauthenticated on the LAN (THREAT_MODEL T-31, T-35)."""
    try:
        doc = await request.json()
    except Exception:  # noqa: BLE001
        return web.json_response({"error": "body must be JSON"}, status=400)
    text = doc.get("text") if isinstance(doc, dict) else None
    if not isinstance(text, str) or not text.strip():
        return web.json_response({"error": "text must be a non-empty string"}, status=400)
    if len(text) > MANUAL_EVENT_MAX_CHARS:
        return web.json_response({"error": f"text longer than {MANUAL_EVENT_MAX_CHARS} chars"}, status=413)
    logger.info("vault: manual-inference event from %s (%d chars)", request.remote, len(text))   # text never logged
    try:
        status, data = await _edge_call("POST", "/admin/events", body={
            "event_type": "manual_inference", "state": "triggered", "raw_payload": text})
    except RuntimeError as exc:
        return web.json_response({"error": str(exc)}, status=503)
    except Exception as exc:  # noqa: BLE001
        return web.json_response({"error": f"trusted-edge unreachable ({type(exc).__name__})"}, status=502)
    return web.json_response(data, status=status)


async def handle_vault_events(request: web.Request) -> web.Response:
    try:
        limit = max(1, min(int(request.query.get("limit", "10")), 20))
    except ValueError:
        return web.json_response({"error": "limit must be an integer"}, status=400)
    return await _edge_proxy("GET", f"/admin/events?limit={limit}")


def _sanitize_audit_entry(obj: Any) -> Any:
    if isinstance(obj, dict):
        obj.pop("client_token", None)
        if "auth" in obj and isinstance(obj["auth"], dict):
            obj["auth"].pop("client_token", None)
        for k, v in list(obj.items()):
            _sanitize_audit_entry(v)
    elif isinstance(obj, list):
        for item in obj:
            _sanitize_audit_entry(item)
    return obj


async def handle_vault_audit_log(request: web.Request) -> web.Response:
    try:
        limit = max(1, min(int(request.query.get("limit", "50")), 100))
    except ValueError:
        return web.json_response({"error": "limit must be an integer"}, status=400)

    cred_dir = os.environ.get("CREDENTIALS_DIRECTORY", "")
    mac_key_path = os.path.join(cred_dir, "mac-key") if cred_dir else ""
    if not mac_key_path or not os.path.exists(mac_key_path):
        return web.json_response({"error": "Mac SSH key credential (mac-key) not found in credentials directory"}, status=503)

    # Tail a larger buffer (4x limit) so that after filtering out lookup-self events,
    # we still return a complete and beautifully populated list of the newest entries.
    cmd = [
        "ssh",
        "-i", mac_key_path,
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ConnectTimeout=5",
        f"{MAC_USER}@{MAC_IP}",
        f"date +%s && tail -n {limit * 4} ~/edge-device-demo/vault/logs/audit.log"
    ]

    try:
        proc = await asyncio.create_subprocess_exec(
            cmd[0], *cmd[1:],
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        out, err = await asyncio.wait_for(proc.communicate(), timeout=10)
    except asyncio.TimeoutError:
        try:
            proc.kill()
        except Exception:
            pass
        return web.json_response({"error": "SSH command timed out"}, status=504)
    except Exception as exc:
        return web.json_response({"error": f"SSH execution failed: {exc}"}, status=500)

    jetson_time = int(time.time())

    if proc.returncode != 0:
        err_msg = err.decode().strip()
        logger.warning("Vault audit SSH command failed: %s", err_msg)
        return web.json_response({"error": f"SSH command failed with code {proc.returncode}: {err_msg}"}, status=500)

    raw_lines = out.decode().splitlines()
    if not raw_lines:
        return web.json_response({"lines": [], "clock_skew_s": 0, "jetson_time": jetson_time, "mac_time": jetson_time})

    try:
        mac_time = int(raw_lines[0].strip())
        skew = abs(jetson_time - mac_time)
        log_start_idx = 1
    except ValueError:
        # Fallback if first line is not a timestamp
        mac_time = jetson_time
        skew = 0
        log_start_idx = 0

    parsed_lines = []
    for line in raw_lines[log_start_idx:]:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            # Filter out auth/token/lookup-self events to remove repetitive background token-check noise
            path = obj.get("request", {}).get("path", "")
            if "auth/token/lookup-self" in path:
                continue
            _sanitize_audit_entry(obj)
            parsed_lines.append(obj)
        except json.JSONDecodeError:
            pass

    # Return only the newest entries that fit the requested limit
    parsed_lines = parsed_lines[-limit:]

    return web.json_response({
        "lines": parsed_lines,
        "clock_skew_s": skew,
        "jetson_time": jetson_time,
        "mac_time": mac_time
    })


async def _reader_login(force: bool = False) -> str:
    """AppRole login for control-plane-reader (Transit decrypt ONLY).  Token cached until 30 s before expiry."""
    if not force and _reader_token["token"] and time.monotonic() < _reader_token["expires"]:
        return _reader_token["token"]
    try:
        cred = json.loads(_read_credential(CONTROL_READER_CREDENTIAL_ID))
        role_id, secret_id = cred["role_id"], cred["secret_id"]
    except (ValueError, KeyError, TypeError):
        raise RuntimeError("control-reader credential missing or malformed")
    status, data = await _vault_call("POST", "auth/approle/login",
                                     body={"role_id": role_id, "secret_id": secret_id})
    del secret_id
    if status != 200 or "auth" not in data:
        raise RuntimeError(f"AppRole login failed (HTTP {status})")
    _reader_token["token"] = data["auth"]["client_token"]
    _reader_token["expires"] = time.monotonic() + max(0, int(data["auth"].get("lease_duration", 0)) - 30)
    return _reader_token["token"]


async def handle_vault_decrypt(request: web.Request) -> web.Response:
    """POST {"ciphertext": <raw_payload: base64 nonce(12)+AES-GCM ct+tag>, "encrypted_datakey": "vault:v1:..."}
    -> {"plaintext": "..."}.  The DEK exists only as a local variable in this request; nothing is cached."""
    try:
        body = await request.json()
        payload_b64 = body["ciphertext"]
        wrapped = body["encrypted_datakey"]
    except Exception:  # noqa: BLE001
        return web.json_response({"error": "body must be JSON with ciphertext and encrypted_datakey"}, status=400)
    if (not isinstance(payload_b64, str) or not isinstance(wrapped, str) or not payload_b64
            or len(payload_b64) > DECRYPT_MAX_CHARS or not wrapped.startswith("vault:v") or len(wrapped) > 4096):
        return web.json_response({"error": "malformed ciphertext / encrypted_datakey"}, status=400)
    try:
        from cryptography.exceptions import InvalidTag
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    except ImportError:
        return web.json_response({"error": "python 'cryptography' is not installed in the WebUI venv"}, status=503)
    try:
        raw = base64.b64decode(payload_b64, validate=True)
    except Exception:  # noqa: BLE001
        return web.json_response({"error": "ciphertext is not valid base64"}, status=400)
    if len(raw) < 12 + 16:
        return web.json_response({"error": "ciphertext too short"}, status=400)

    dek_b64 = None
    try:
        for attempt in (0, 1):
            token = await _reader_login(force=bool(attempt))
            status, data = await _vault_call("POST", f"{TRANSIT_MOUNT}/decrypt/{TRANSIT_KEY}", token=token,
                                             body={"ciphertext": wrapped})
            if status == 403 and attempt == 0:
                continue                      # token expired/revoked: log in again once
            break
        if status != 200:
            return web.json_response({"error": f"Transit decrypt refused (HTTP {status})"}, status=502)
        dek_b64 = data["data"]["plaintext"]
    except RuntimeError as exc:
        return web.json_response({"error": str(exc)}, status=503)
    except Exception as exc:  # noqa: BLE001
        return web.json_response({"error": f"Vault unreachable ({type(exc).__name__})"}, status=502)

    try:
        dek = base64.b64decode(dek_b64)
        plaintext = AESGCM(dek).decrypt(raw[:12], raw[12:], None).decode("utf-8")
    except InvalidTag:
        return web.json_response({"error": "AES-GCM authentication failed (wrong key or tampered ciphertext)"}, status=422)
    except Exception:  # noqa: BLE001
        return web.json_response({"error": "payload could not be decrypted"}, status=422)
    finally:
        dek_b64 = None
        dek = None
    return web.json_response({"plaintext": plaintext})



# ── TLS Certificate Generator ────────────────────────────────────────────────

def ensure_tls_certificates(cert_path: Path, key_path: Path):
    """Generates self-signed TLS cert if missing for HTTPS / WebRTC permissions."""
    if cert_path.exists() and key_path.exists():
        logger.info(f"Using existing TLS cert: {cert_path}")
        return

    cert_path.parent.mkdir(parents=True, exist_ok=True)
    logger.info("Generating self-signed TLS certificate for HTTPS...")
    cmd = (
        f'openssl req -x509 -newkey rsa:2048 -nodes '
        f'-keyout "{key_path}" -out "{cert_path}" -days 365 '
        f'-subj "/CN=jetson-orin-nano.local/O=EdgeSecurityDemo" '
        f'>/dev/null 2>&1'
    )
    res = os.system(cmd)
    if res != 0:
        logger.error("Failed to generate TLS certificate using openssl CLI.")
    else:
        logger.info(f"TLS certificate generated at {cert_path}")


# ── HTTP Redirect Server (Port 8091 -> 8443) ──────────────────────────────────

async def start_redirect_server(http_port: int, https_port: int):
    async def redirect_handler(request: web.Request) -> web.Response:
        host = request.host.split(":")[0]
        target_url = f"https://{host}:{https_port}{request.path_qs}"
        raise web.HTTPFound(target_url)

    app = web.Application()
    app.router.add_get("/{tail:.*}", redirect_handler)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "0.0.0.0", http_port)
    await site.start()
    logger.info(f"HTTP -> HTTPS redirect server listening on http://0.0.0.0:{http_port}")


# ── Application Factory & Startup ─────────────────────────────────────────────

def create_app() -> web.Application:
    app = web.Application()

    # Routes
    app.router.add_get("/", handle_index)
    app.router.add_get("/health", handle_health)
    app.router.add_get("/video_feed", handle_video_feed)
    app.router.add_get("/api/status", handle_api_status)
    app.router.add_post("/api/reconnect_camera", handle_api_reconnect_camera)
    app.router.add_get("/api/capture_frame", handle_capture_frame)
    app.router.add_get("/api/telemetry", handle_api_telemetry)
    app.router.add_get("/ws/telemetry", handle_ws_telemetry)
    app.router.add_post("/api/infer", handle_api_infer)
    app.router.add_post("/api/infer_stream", handle_api_infer_stream)
    app.router.add_get("/api/default-prompt", handle_api_default_prompt)
    app.router.add_get("/api/openshell/policy", handle_openshell_policy)
    app.router.add_get("/api/openshell/events", handle_openshell_events)
    app.router.add_get("/api/openshell/audit", handle_openshell_audit)
    app.router.add_post("/api/openshell/test-url", handle_openshell_test_url)
    app.router.add_get("/api/vault/identity", handle_vault_identity)
    app.router.add_get("/api/vault/db-credential", handle_vault_db_credential)
    app.router.add_post("/api/vault/rotate-credential", handle_vault_rotate_credential)
    app.router.add_get("/api/vault/events", handle_vault_events)
    app.router.add_post("/api/vault/decrypt", handle_vault_decrypt)
    app.router.add_post("/api/vault/manual-event", handle_vault_manual_event)
    app.router.add_get("/api/vault/audit-log", handle_vault_audit_log)


    # Static assets
    if STATIC_DIR.exists():
        app.router.add_static("/static/", path=str(STATIC_DIR), name="static")

    return app


async def main():
    parser = argparse.ArgumentParser(description="Live VLM WebUI Server")
    parser.add_argument("--port", type=int, default=8443, help="HTTPS port (default 8443)")
    parser.add_argument("--redirect-port", type=int, default=8091, help="HTTP redirect port (default 8091)")
    parser.add_argument("--no-tls", action="store_true", help="Run plain HTTP without TLS")
    args = parser.parse_args()

    # Start hardware telemetry & video capture
    telemetry.start()
    video_manager.start()

    # Launch background tasks
    asyncio.create_task(video_manager.capture_loop())
    asyncio.create_task(telemetry_broadcast_loop())

    # Build app
    app = create_app()
    runner = web.AppRunner(app)
    await runner.setup()

    ssl_context = None
    if not args.no_tls:
        cert_file = TLS_DIR / "cert.pem"
        key_file = TLS_DIR / "key.pem"
        ensure_tls_certificates(cert_file, key_file)

        ssl_context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        ssl_context.load_cert_chain(str(cert_file), str(key_file))

        # Start HTTP redirect server on port 8091
        await start_redirect_server(args.redirect_port, args.port)

    site = web.TCPSite(runner, "0.0.0.0", args.port, ssl_context=ssl_context)
    await site.start()

    protocol = "https" if ssl_context else "http"
    logger.info(f"╔═══════════════════════════════════════════════════════════════╗")
    logger.info(f"║ Live VLM WebUI listening on {protocol}://0.0.0.0:{args.port}          ║")
    logger.info(f"║ Telemetry WebSocket: {protocol.replace('http','ws')}://0.0.0.0:{args.port}/ws/telemetry  ║")
    logger.info(f"╚═══════════════════════════════════════════════════════════════╝")

    try:
        while True:
            await asyncio.sleep(3600)
    except (asyncio.CancelledError, KeyboardInterrupt):
        logger.info("Shutting down WebUI server...")
    finally:
        video_manager.stop()
        telemetry.stop()
        await runner.cleanup()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
