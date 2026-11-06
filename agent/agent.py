#!/usr/bin/env python3
# agent/agent.py
# Home camera AI agent running inside the NVIDIA OpenShell Edge Supervisor
# sandbox on the Jetson Orin Nano Super.
#
# Session 3-5i — change-triggered inference design:
#
#   POLL loop (every POLL_INTERVAL_SEC, default 1 s):
#     1. GET /frame.jpg from trusted-edge via the `edge-ingest` provider.
#        The supervisor injects the X-Edge-Key header; the agent never sees
#        the key value.
#     2. Compute mean-absolute-difference (MAD) on a 64×64 downsampled
#        grayscale version of the JPEG.  Skip inference if MAD < MOTION_THRESHOLD
#        AND fewer than MAX_IDLE_INFER_SEC have passed since the last inference.
#     3. If motion detected (or idle too long):
#        a. POST /v1/chat/completions to the VLM via the `cosmos-vlm` provider.
#        b. Parse keywords; track open-state durations.
#        c. POST /events to trusted-edge for each detected event keyword.
#           trusted-edge handles encryption and the DB write.
#        d. Reset the motion baseline to the current frame.
#
# Rationale: with `llama-server -np 1`, every inference call blocks for 2–4 s.
# Inferring on every frame wastes the slot and fills the DB with duplicate rows.
# Only infer when something has changed.  The DB row count stays proportional
# to real events, not to the frame rate.
#
# What this process holds:
#   - Latest JPEG bytes and a 64×64 grayscale baseline array (motion detection).
#   - VLM text responses (needed for event parsing).
#   - Opaque openshell:resolve:env:… placeholder strings (never resolved here).
#
# What this process does NOT hold:
#   - Any Vault token.
#   - The RTSP URL or camera password.
#   - Any DB credential.
#   - The Transit DEK or the AES-GCM key.
#   - The ingest API key plaintext.

import base64
import io
import json
import os
import re
import sys
import time

import requests
from PIL import Image

# ── Configuration (all non-secret; overridable via environment) ───────────────

# Base URL of the trusted-edge ingest service.  The `edge-ingest` provider
# profile authorises POST /events and GET /frame.jpg on this host.
# Use the DNS name (not an IP literal) so the policy accepts it.
JETSON_HOSTNAME = os.environ.get("JETSON_HOSTNAME", "jetson.localdomain")
TRUSTED_EDGE_PORT = os.environ.get("TRUSTED_EDGE_PORT", "8095")
VLM_PORT = os.environ.get("VLM_PORT", "8090")

INGEST_BASE = os.environ.get("INGEST_BASE", f"http://{JETSON_HOSTNAME}:{TRUSTED_EDGE_PORT}")

# VLM endpoint.  The `cosmos-vlm` provider profile authorises
# POST /v1/chat/completions on local VLM port.
VLM_URL = os.environ.get("VLM_URL", f"http://{JETSON_HOSTNAME}:{VLM_PORT}/v1/chat/completions")

# Ingest key placeholder — the gateway injects this value into the sandbox env
# as "INGEST_KEY" (the credential's env_var name from the edge-ingest profile,
# see scripts/15-install-gateway-vault-driver.sh line 419: env_vars: [INGEST_KEY]).
# The placeholder value (openshell:resolve:env:v<N>_INGEST_KEY) is substituted
# with the real key by the supervisor before the request leaves the sandbox.
# The agent never learns the actual key value.
INGEST_KEY_PLACEHOLDER = os.environ.get("INGEST_KEY", "openshell:resolve:env:v1_INGEST_KEY")

# How often to poll for a new frame (seconds).  Fast enough to detect motion
# without saturating trusted-edge.  Default: 1 s.
POLL_INTERVAL_SEC = float(os.environ.get("POLL_INTERVAL_SEC", "1"))

# Minimum seconds between VLM inference calls even when motion is detected
# continuously (e.g. a slow camera pan).  Prevents flooding the VLM.
MIN_INFER_INTERVAL_SEC = float(os.environ.get("MIN_INFER_INTERVAL_SEC", "5"))

# Motion threshold: mean-absolute-difference of 64×64 grayscale pixels,
# 0–255 scale.  10 ≈ 4 % brightness change across the frame.
MOTION_THRESHOLD = float(os.environ.get("MOTION_THRESHOLD", "10"))

# Camera identifier written into every event POST body.
CAMERA_ID = os.environ.get("CAMERA_ID", "cam-default")

# Camera profile — controls the VLM prompt, event keywords, and synonyms.
#   indoor   : general object/person detection; no gate/garage/door (e.g. demo shelf cam)
#   outdoor  : full security detection: gate/garage/door state + person/animal/package
# Set via CAMERA_PROFILE env var in the sandbox --env.  Default: indoor.
CAMERA_PROFILE = os.environ.get("CAMERA_PROFILE", "indoor")

# VLM max_tokens — capped to keep individual inference under ~3 s on Orin Nano
# at Q4_K_M.  300 tokens ≈ ~200 words, more than enough for a scene description.
VLM_MAX_TOKENS = int(os.environ.get("VLM_MAX_TOKENS", "300"))

# Downscale size for the motion-detection comparison (pixels per side).
MOTION_DOWNSAMPLE = 64

# ── Camera profiles ───────────────────────────────────────────────────────────
# Each profile defines:
#   prompt    — what the VLM is asked to describe
#   keywords  — ordered list of canonical event_type values to report
#   synonyms  — mapping from VLM words → canonical keyword
#   stateful  — keywords that track open/close duration (outdoor only)

_PROFILES: dict[str, dict] = {
    # Indoor demo camera: detect objects and people in frame.
    # No gate/garage/door — they will never appear on this stream.
    # event_mode="indoor": posts a single event per inference —
    #   object_detected/triggered  when a known object was identified
    #   scene_described/triggered  when the VLM text contains no known keyword
    #                              (Session 5-5b: was "motion_detected", which implied measured motion)
    "indoor": {
        "prompt": (
            "Describe what you see in this camera frame. "
            "Be specific about any objects, people, or animals visible. "
            "Answer concisely."
        ),
        "keywords": ["person", "animal", "package"],
        "synonyms": {
            "person": "person", "people": "person", "man": "person", "woman": "person",
            "child": "person", "hand": "person", "finger": "person", "human": "person",
            "animal": "animal", "cat": "animal", "dog": "animal", "bird": "animal",
            "rabbit": "animal", "squirrel": "animal", "fox": "animal",
            "package": "package", "parcel": "package", "box": "package",
            "delivery": "package", "bag": "package",
        },
        "stateful": [],
        "event_mode": "indoor",
    },
    # Outdoor security camera: gate/garage/door state + intruder/delivery detection.
    # event_mode="outdoor": posts one event per keyword with open/close state tracking.
    "outdoor": {
        "prompt": (
            "Describe what you see in this home security camera frame. "
            "Be specific about any objects, people, animals, or packages visible. "
            "If a gate, garage door, or door is visible, state whether it is open or closed. "
            "Answer concisely."
        ),
        "keywords": ["gate", "garage", "door", "person", "animal", "package"],
        "synonyms": {
            "person": "person", "people": "person", "man": "person", "woman": "person",
            "child": "person", "hand": "person", "human": "person",
            "animal": "animal", "cat": "animal", "dog": "animal", "bird": "animal",
            "rabbit": "animal", "squirrel": "animal", "fox": "animal",
            "package": "package", "parcel": "package", "box": "package",
            "delivery": "package", "bag": "package",
            "gate": "gate", "garage": "garage", "door": "door",
        },
        "stateful": ["gate", "garage", "door"],
        "event_mode": "outdoor",
    },
}

def _load_profile(name: str) -> dict:
    if name not in _PROFILES:
        print(f"[agent] unknown CAMERA_PROFILE '{name}', falling back to 'indoor'", file=sys.stderr)
        name = "indoor"
    p = _PROFILES[name]
    print(f"[agent] CAMERA_PROFILE       : {name} "
          f"(keywords: {p['keywords']}, stateful: {p['stateful']})")
    return p

# Open-state trackers: {object_key: monotonic start timestamp}.
open_state: dict = {}


# ── Motion detection ──────────────────────────────────────────────────────────

def _jpeg_to_gray64(jpeg_bytes: bytes):
    """
    Decode a JPEG and return a flat list of MOTION_DOWNSAMPLE² uint8 values
    (grayscale, row-major).  Returns None on decode failure.
    Uses Pillow (python3-pil), installed system-wide in the sandbox image.
    """
    try:
        img = Image.open(io.BytesIO(jpeg_bytes)).convert("L")
        img = img.resize((MOTION_DOWNSAMPLE, MOTION_DOWNSAMPLE), Image.BILINEAR)
        return list(img.tobytes())
    except Exception:
        return None


def _mad(a, b) -> float:
    """Mean absolute difference between two same-length uint8 lists."""
    if len(a) != len(b):
        return 255.0
    return sum(abs(x - y) for x, y in zip(a, b)) / len(a)


# ── Frame fetch ───────────────────────────────────────────────────────────────

def fetch_frame() -> tuple[bytes | None, bool]:
    """
    GET /frame.jpg from trusted-edge.

    Returns (jpeg_bytes, snapshot_pending).
    snapshot_pending is True when trusted-edge set X-Snapshot-Pending: 1 on the
    response — meaning a remote POST /snapshot was received and this frame
    should be inferred regardless of the motion MAD.  The flag is consumed
    (cleared) by trusted-edge on this response.
    """
    try:
        resp = requests.get(
            f"{INGEST_BASE}/frame.jpg",
            headers={"X-Edge-Key": INGEST_KEY_PLACEHOLDER},
            timeout=10,
        )
        resp.raise_for_status()
        snapshot = resp.headers.get("X-Snapshot-Pending") == "1"
        return resp.content, snapshot
    except Exception as exc:  # noqa: BLE001
        print(f"[agent] fetch_frame failed: {exc}", file=sys.stderr)
        return None, False


# ── VLM inference ─────────────────────────────────────────────────────────────

def call_vlm(jpeg_bytes: bytes, prompt: str) -> str:
    """POST /v1/chat/completions and return the model text."""
    b64 = base64.b64encode(jpeg_bytes).decode("ascii")
    data_uri = f"data:image/jpeg;base64,{b64}"
    payload = {
        "model": "cosmos-reason2-2b",
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
                    {"type": "image_url", "image_url": {"url": data_uri}},
                ],
            }
        ],
        "temperature": 0.2,
        "max_tokens": VLM_MAX_TOKENS,
    }
    resp = requests.post(VLM_URL, json=payload, timeout=60)
    resp.raise_for_status()
    data = resp.json()
    message = data["choices"][0]["message"]
    text = message.get("content") or ""
    reasoning = message.get("reasoning_content") or ""
    if reasoning:
        text = text + ("\n" + reasoning if text else reasoning)
    return text


# ── Event parsing ─────────────────────────────────────────────────────────────

def parse_events(text: str, profile: dict) -> list:
    """Return keywords positively present in the VLM text for the given profile.

    Split on sentence boundaries only (.!?;) so that list items like
    'no visible gate, garage door, or door' stay in one sentence and
    the negation covers all three keywords.  A keyword is counted only
    when its sentence contains no negation marker.
    """
    synonyms  = profile["synonyms"]
    keywords  = profile["keywords"]
    sentences = re.split(r'[.!?;]', text.lower())
    negation_markers = (
        " no ", " not ", " without ", " isn't ", " aren't ",
        " is not ", " are not ", " cannot ", " can't ",
        "no visible", "there is no", "there are no",
    )
    found = set()
    for sentence in sentences:
        padded = " " + sentence + " "
        if any(m in padded for m in negation_markers):
            continue
        words = re.findall(r"[a-z]+", sentence)
        for word in words:
            canonical = synonyms.get(word)
            if canonical:
                found.add(canonical)
    return [kw for kw in keywords if kw in found]


# ── Event POST ────────────────────────────────────────────────────────────────

def post_event(
    event_type: str,
    state: str,
    *,
    raw_payload: str,
    duration_s: float | None = None,
    warned: bool = False,
) -> None:
    """
    POST /events to trusted-edge.  The supervisor injects the ingest key.
    trusted-edge validates, encrypts and writes to PostgreSQL.
    """
    body: dict = {
        "event_type": event_type,
        "state": state,
        "raw_payload": raw_payload,
        "warned": warned,
    }
    if duration_s is not None:
        body["duration_s"] = int(duration_s)

    try:
        resp = requests.post(
            f"{INGEST_BASE}/events",
            headers={
                "X-Edge-Key": INGEST_KEY_PLACEHOLDER,
                "Content-Type": "application/json",
            },
            data=json.dumps(body),
            timeout=15,
        )
        if resp.status_code in (200, 201):
            row_id = resp.json().get("id", "?")
            print(f"[agent] event OK — type={event_type} state={state} row_id={row_id}")
        else:
            print(
                f"[agent] event {resp.status_code} — {event_type}/{state}: {resp.text[:120]}",
                file=sys.stderr,
            )
    except Exception as exc:  # noqa: BLE001
        print(f"[agent] event POST failed ({event_type}/{state}): {exc}", file=sys.stderr)


# ── Main loop ─────────────────────────────────────────────────────────────────

def main() -> None:
    print(f"[agent] camera-agent starting (python {sys.version.split()[0]})")
    print(f"[agent] INGEST_BASE          : {INGEST_BASE}")
    print(f"[agent] VLM_URL              : {VLM_URL}")
    ingest_key_source = "env:INGEST_KEY (gateway-injected)" if os.environ.get("INGEST_KEY") else "default fallback"
    print(f"[agent] INGEST_KEY source    : {ingest_key_source}")
    print(f"[agent] CAMERA_ID            : {CAMERA_ID}")
    print(f"[agent] POLL_INTERVAL        : {POLL_INTERVAL_SEC}s")
    print(f"[agent] MIN_INFER_INTERVAL   : {MIN_INFER_INTERVAL_SEC}s")
    print(f"[agent] MOTION_THRESHOLD     : {MOTION_THRESHOLD}/255")
    print(f"[agent] VLM_MAX_TOKENS       : {VLM_MAX_TOKENS}")

    profile = _load_profile(CAMERA_PROFILE)

    baseline_gray = None          # 64×64 grayscale of the last inferred frame
    last_infer_t  = 0.0           # monotonic time of the last MIN_INFER_INTERVAL check

    while True:
        loop_start = time.monotonic()

        # ── 1. Fetch frame ────────────────────────────────────────────────────
        jpeg, snapshot_req = fetch_frame()
        if jpeg is None:
            time.sleep(POLL_INTERVAL_SEC)
            continue

        # ── 2. Motion / snapshot check ────────────────────────────────────────
        now = time.monotonic()
        gray = _jpeg_to_gray64(jpeg)

        if gray is not None and baseline_gray is not None:
            mad = _mad(gray, baseline_gray)
        else:
            mad = 255.0  # first frame or decode failure → always infer on startup

        motion_detected = mad >= MOTION_THRESHOLD
        infer_cooldown  = (now - last_infer_t) < MIN_INFER_INTERVAL_SEC

        reason = ""
        if snapshot_req:
            # Remote POST /snapshot (ingest key) always fires, ignores cooldown.
            # The WebUI no longer uses this path (Session 5-5c): a manual WebUI inference is stored
            # by the WebUI itself via trusted-edge POST /admin/events and triggers no agent inference.
            reason = "snapshot (remote trigger)"
        elif motion_detected and not infer_cooldown:
            reason = f"motion MAD={mad:.1f}"
        # else: skip — no liveness timer; only motion or explicit snapshot writes to DB

        if not reason:
            elapsed = time.monotonic() - loop_start
            sleep_t = max(0.0, POLL_INTERVAL_SEC - elapsed)
            if sleep_t > 0:
                time.sleep(sleep_t)
            continue

        # ── 3. VLM inference ──────────────────────────────────────────────────
        print(f"[agent] {time.strftime('%H:%M:%S')}  trigger={reason}")
        t0 = time.monotonic()
        try:
            text = call_vlm(jpeg, profile["prompt"])
        except Exception as exc:  # noqa: BLE001
            print(f"[agent] VLM inference failed: {exc}", file=sys.stderr)
            time.sleep(POLL_INTERVAL_SEC)
            continue
        vlm_ms = (time.monotonic() - t0) * 1000
        last_infer_t = time.monotonic()
        baseline_gray = gray  # update baseline to the frame we just inferred
        print(f"[agent] vlm={vlm_ms:.0f}ms  text={text[:180]!r}")

        # ── 4. Parse + post events ────────────────────────────────────────────
        events = parse_events(text, profile)
        print(f"[agent] events: {events}")

        event_mode = profile["event_mode"]
        stateful   = profile["stateful"]
        now_mono   = time.monotonic()

        if event_mode == "indoor":
            # Indoor profile: one row per inference, not one per keyword.
            # event_type = object_detected (keyword found) or scene_described (nothing specific).
            # "motion_detected" is not posted: a no-keyword result says nothing about motion (Session 5-5b).
            if events:
                post_event("object_detected", "triggered", raw_payload=text)
            else:
                post_event("scene_described", "triggered", raw_payload=text)

        else:
            # Outdoor profile: one row per keyword, with open/close state tracking.
            for ev in events:
                if ev in stateful:
                    if ev not in open_state:
                        open_state[ev] = now_mono
                        state = "opened"
                    else:
                        state = "open"
                    duration = now_mono - open_state[ev]
                    post_event(ev, state, raw_payload=text, duration_s=duration, warned=False)
                else:
                    post_event(ev, "detected", raw_payload=text)
                    open_state.pop(ev, None)

        # Mark closed for objects tracked but not seen this frame.
        for ev in list(open_state.keys()):
            if ev not in events:
                duration = now_mono - open_state.pop(ev)
                post_event(ev, "closed", raw_payload=text, duration_s=duration)

        # ── 5. Sleep remainder of poll interval ───────────────────────────────
        elapsed = time.monotonic() - loop_start
        sleep_t = max(0.0, POLL_INTERVAL_SEC - elapsed)
        if sleep_t > 0:
            time.sleep(sleep_t)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("[agent] Shutting down.")
