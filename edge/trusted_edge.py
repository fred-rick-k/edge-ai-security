#!/usr/bin/env python3
# edge/trusted_edge.py
# trusted-edge: the ONLY host process that touches the camera, the DEK and the database
# (Session 3-5g).  The sandboxed agent talks to it over HTTP and holds none of these secrets.
#
#   GET  /frame.jpg   latest camera frame as JPEG (503 when older than TE_FRAME_STALE_SEC)
#   POST /events      JSON event -> AES-256-GCM (Transit DEK) -> INSERT into events (dynamic DB cred)
#   anything else     404
#
# Authentication: header X-Edge-Key.  The service never holds the key itself — only its
# SHA-256, read from Vault KV edge-ai-demo-kv/edge-device/ingest-key (field "sha256") with the
# edge token.  Comparison is constant-time.  The key is never logged.
#
# Admin routes (Session 5-3b) — a SEPARATE key, header X-Admin-Key, SHA-256 in Vault KV
# edge-ai-demo-kv/edge-device/admin-key.  The plaintext is held only by the WebUI (systemd LoadCredential=).
# The ingest key (held by the sandbox provider) cannot call them.  Without a provisioned admin key the
# routes answer 503 and everything above is unaffected.
#   GET  /admin/credential         {db_username, lease_ttl_s, lease_id, ...}  — the password is NEVER returned
#   POST /admin/rotate-credential  new lease -> swap -> revoke the old lease (sys/leases/revoke/<id>)
#   GET  /admin/identity           lookup-self of the EDGE token (display_name, policies, ttl, expire_time, path)
#   GET  /admin/events?limit=N     newest stored events, CIPHERTEXT only (raw_payload + encrypted_datakey)
#   POST /admin/events             store the WebUI's own manual-inference text (Session 5-5c).  event_type is
#                                  forced to MANUAL_EVENT_TYPE; encryption + INSERT happen here, the WebUI
#                                  never holds a DB credential or the DEK.  The ingest key cannot post this type.
#
# Secrets handling:
#   - Vault token: read from /run/openshell-edge/vault-token (written by vault-agent, 3-5f).
#   - RTSP URL: fetched from Vault KV edge-ai-demo-kv/edge-device/camera-creds (field rtsp_url)
#     at startup and on every reconnect.  Held in memory only; never written to disk and never
#     logged (only host:port is logged).
#   - DEK plaintext and the dynamic DB credential live in process memory only.
#
# The Vault/DEK/DB helpers below are adapted from agent/agent.py (DataKey, DbCredential,
# request_datakey, request_db_cred, _vault_get, _vault_post).  They are copied, not imported,
# because Session 3-5i removes them from the agent.

import base64
import hashlib
import hmac
import json
import logging
import os
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

# Quiet FFmpeg/OpenCV before cv2 is imported: their error lines can echo the stream URL.
os.environ.setdefault("OPENCV_FFMPEG_CAPTURE_OPTIONS", "rtsp_transport;tcp")
os.environ.setdefault("OPENCV_FFMPEG_LOGLEVEL", "-8")   # AV_LOG_QUIET
os.environ.setdefault("OPENCV_LOG_LEVEL", "SILENT")

import cv2  # noqa: E402
import requests  # noqa: E402
from cryptography.hazmat.primitives.ciphers.aead import AESGCM  # noqa: E402

# ── Configuration (non-secret, overridable via the unit's Environment=) ───────
BIND_ADDR = os.environ.get("TE_BIND", os.environ.get("JETSON_IP", "127.0.0.1"))
BIND_PORT = int(os.environ.get("TE_PORT", os.environ.get("TRUSTED_EDGE_PORT", "8095")))

VAULT_ADDR       = os.environ.get("VAULT_ADDR", f"https://{os.environ.get('MAC_IP', '127.0.0.1')}:{os.environ.get('VAULT_PORT', '8200')}")
VAULT_CACERT     = os.environ.get("VAULT_CACERT", "/opt/trusted-edge/vault.crt")
VAULT_TOKEN_FILE = os.environ.get("VAULT_TOKEN_FILE", "/run/openshell-edge/vault-token")

KV_MOUNT        = "edge-ai-demo-kv"
CAMERA_KV_PATH  = f"{KV_MOUNT}/data/edge-device/camera-creds"
INGEST_KV_PATH  = f"{KV_MOUNT}/data/edge-device/ingest-key"
ADMIN_KV_PATH   = f"{KV_MOUNT}/data/edge-device/admin-key"
TRANSIT_MOUNT   = "edge-ai-demo-encryption-transit"
TRANSIT_KEY     = "edge-telemetry"
DB_CREDS_PATH   = "edge-ai-demo-database/creds/edge-camera-agent"

DB_HOST   = os.environ.get("DB_HOST", os.environ.get("MAC_IP", "127.0.0.1"))
DB_PORT   = int(os.environ.get("DB_PORT", os.environ.get("POSTGRES_PORT", "5432")))
DB_NAME   = os.environ.get("DB_NAME", os.environ.get("POSTGRES_DB", "edge_demo"))
CAMERA_ID = os.environ.get("CAMERA_ID", "cam-default")

FRAME_STALE_SEC     = float(os.environ.get("TE_FRAME_STALE_SEC", "5"))
ENCODE_INTERVAL_SEC = float(os.environ.get("TE_ENCODE_INTERVAL_SEC", "0.5"))
JPEG_QUALITY        = int(os.environ.get("TE_JPEG_QUALITY", "80"))
MAX_WIDTH           = int(os.environ.get("TE_MAX_WIDTH", "1280"))
MAX_BODY_BYTES      = int(os.environ.get("TE_MAX_BODY_BYTES", "16384"))
MAX_PAYLOAD_CHARS   = 8000
STATS_INTERVAL_SEC  = 60

# Token buckets: (burst, refill per second).
EVENTS_LIMIT   = (20, 1.0)
FRAME_LIMIT    = (20, 5.0)
AUTHFAIL_LIMIT = (10, 0.2)
SNAPSHOT_LIMIT = (4, 0.1)    # 4 burst, 1 per 10 s sustained
ADMIN_LIMIT    = (20, 2.0)
ROTATE_LIMIT   = (2, 0.05)   # 2 burst, 1 per 20 s sustained: each rotation creates and drops a PostgreSQL role
ADMIN_EVENTS_MAX = 20

DEK_REFRESH_BEFORE_EXPIRY_SEC    = 60
DBCRED_REFRESH_BEFORE_EXPIRY_SEC = 60
CRED_CHECK_INTERVAL_SEC          = 15    # background renewal poll (Session 5-5e)

# Fixed allow-lists.  event_type = agent.py EVENT_KEYWORDS; state = values agent.py emits
# (opened/open/detected) plus the values documented in vault/schema.sql.
MANUAL_EVENT_TYPE = "manual_inference"   # written ONLY via POST /admin/events (Session 5-5c)
EVENT_TYPES = frozenset({
    "gate", "garage", "door", "person", "animal", "package",  # outdoor profile
    "object_detected", "scene_described",                      # indoor profile (Session 5-5b)
    "motion_detected",                                         # legacy: rows written before 5-5b; no longer posted by agent.py
    MANUAL_EVENT_TYPE,
})
EVENT_STATES = frozenset({"opened", "open", "closed", "detected", "present", "absent", "triggered"})
EVENT_FIELDS = frozenset({"event_type", "state", "raw_payload", "duration_s", "warned"})

log = logging.getLogger("trusted-edge")


# ── Vault helpers (adapted from agent/agent.py) ──────────────────────────────

def _vault_token() -> str:
    with open(VAULT_TOKEN_FILE) as fh:
        tok = fh.read().strip()
    if not tok:
        raise RuntimeError(f"Vault token file {VAULT_TOKEN_FILE} is empty")
    return tok


def _verify():
    return VAULT_CACERT if os.path.isfile(VAULT_CACERT) else True


def _vault_get(path: str, *, token: str) -> dict:
    resp = requests.get(f"{VAULT_ADDR}/v1/{path}", headers={"X-Vault-Token": token},
                        verify=_verify(), timeout=10)
    resp.raise_for_status()
    return resp.json()


def _vault_post(path: str, *, token: str, body: dict | None = None) -> dict:
    resp = requests.post(f"{VAULT_ADDR}/v1/{path}", headers={"X-Vault-Token": token},
                         json=body or {}, verify=_verify(), timeout=10)
    resp.raise_for_status()
    # Some Vault endpoints answer 204 No Content (e.g. sys/leases/revoke): no JSON body to parse.
    return resp.json() if resp.content else {}


class DataKey:
    """AES-256-GCM DEK from Vault Transit datakey/plaintext.  Plaintext lives in memory only."""

    def __init__(self, plaintext_b64: str, ciphertext: str, expires_at: float):
        raw = base64.b64decode(plaintext_b64)
        if len(raw) != 32:
            raise ValueError(f"Expected 32-byte DEK, got {len(raw)}")
        self._aesgcm = AESGCM(raw)
        self.ciphertext = ciphertext          # vault:v1:... — stored in the DB row
        self.expires_at = expires_at

    def encrypt(self, plaintext: str) -> str:
        nonce = os.urandom(12)
        ct = self._aesgcm.encrypt(nonce, plaintext.encode(), None)
        return base64.b64encode(nonce + ct).decode("ascii")

    def needs_refresh(self) -> bool:
        return (self.expires_at - time.monotonic()) < DEK_REFRESH_BEFORE_EXPIRY_SEC


def request_datakey() -> DataKey | None:
    try:
        data = _vault_post(f"{TRANSIT_MOUNT}/datakey/plaintext/{TRANSIT_KEY}",
                           token=_vault_token()).get("data", {})
        if not data.get("plaintext") or not data.get("ciphertext"):
            raise ValueError(f"unexpected datakey response keys: {list(data)}")
        dk = DataKey(data["plaintext"], data["ciphertext"], time.monotonic() + 5 * 60)
        log.info("Transit datakey obtained")
        return dk
    except Exception as exc:  # noqa: BLE001
        log.warning("could not obtain Transit datakey: %s", exc)
        return None


class DbCredential:
    """Short-lived PostgreSQL credential from the Vault database engine (memory only)."""

    def __init__(self, username: str, password: str, expires_at: float, lease_id: str = "",
                 lease_sec: int = 0):
        self.username = username
        self.password = password
        self.expires_at = expires_at
        self.lease_id = lease_id
        self.lease_sec = lease_sec

    def needs_refresh(self) -> bool:
        return (self.expires_at - time.monotonic()) < DBCRED_REFRESH_BEFORE_EXPIRY_SEC


def request_db_cred() -> DbCredential | None:
    try:
        result = _vault_get(DB_CREDS_PATH, token=_vault_token())
        data = result.get("data", {})
        lease_sec = result.get("lease_duration", 300)
        if not data.get("username") or not data.get("password"):
            raise ValueError(f"unexpected DB cred response keys: {list(data)}")
        log.info("dynamic DB credential issued: user=%s (TTL %ss)", data["username"], lease_sec)
        return DbCredential(data["username"], data["password"], time.monotonic() + lease_sec,
                            str(result.get("lease_id", "")), int(lease_sec))
    except Exception as exc:  # noqa: BLE001
        log.warning("could not obtain dynamic DB credential: %s", exc)
        return None


def revoke_db_lease(lease_id: str) -> tuple[bool, str]:
    """Revoke one DB lease: POST sys/leases/revoke/<lease_id> (path form, sync=true) with the edge token.

    The edge policy grants only sys/leases/revoke/edge-ai-demo-database/creds/edge-camera-agent/*, so the
    id is checked against that prefix first.  Returns (revoked, reason-for-humans)."""
    prefix = DB_CREDS_PATH + "/"
    if not lease_id.startswith(prefix) or len(lease_id) <= len(prefix) \
            or any(c in lease_id for c in ("..", "?", "#", " ", "\\")):
        return False, "lease id outside the permitted prefix"
    try:
        _vault_post(f"sys/leases/revoke/{lease_id}", token=_vault_token(), body={"sync": True})
        return True, "revoked"
    except Exception as exc:  # noqa: BLE001
        status = getattr(getattr(exc, "response", None), "status_code", None)
        return False, f"revoke failed: {type(exc).__name__}" + (f" HTTP {status}" if status else "")


# ── Vault-sourced secrets: ingest-key hash and RTSP URL ──────────────────────

class PlaceholderCameraUrl(RuntimeError):
    pass


def load_key_hash(kv_path: str) -> str:
    """SHA-256 hex of an API key (KV field 'sha256').  Raises if absent."""
    data = _vault_get(kv_path, token=_vault_token()).get("data", {}).get("data", {})
    h = str(data.get("sha256", "")).strip().lower()
    if len(h) != 64 or any(c not in "0123456789abcdef" for c in h):
        raise RuntimeError(f"{kv_path} has no valid 'sha256' field")
    return h


def load_ingest_key_hash() -> str:
    """SHA-256 hex of the ingest key (KV field 'sha256').  Raises if absent."""
    return load_key_hash(INGEST_KV_PATH)


def fetch_rtsp_url() -> str:
    """Fetch the RTSP URL from Vault KV.  Refuses the init-vault.sh placeholder."""
    data = _vault_get(CAMERA_KV_PATH, token=_vault_token()).get("data", {}).get("data", {})
    url = data.get("rtsp_url", "")
    if not url:
        raise RuntimeError(f"{CAMERA_KV_PATH} has no 'rtsp_url' field")
    parts = urlsplit(url)
    if parts.scheme != "rtsp" or not parts.hostname:
        raise RuntimeError("rtsp_url in Vault is not a valid rtsp:// URL")
    if parts.username == "user" and parts.password == "changeme":
        raise PlaceholderCameraUrl(
            "rtsp_url in Vault is still the init-vault.sh placeholder (rtsp://user:changeme@…). "
            f"Write the real URL to {KV_MOUNT}/edge-device/camera-creds field rtsp_url."
        )
    return url


def url_host(url: str) -> str:
    """host:port only — never userinfo, path or query."""
    p = urlsplit(url)
    return f"{p.hostname}:{p.port or 554}"


# ── Camera reader thread ─────────────────────────────────────────────────────

def _vm_rss_mb() -> float:
    try:
        with open("/proc/self/status") as fh:
            for line in fh:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1]) / 1024.0
    except OSError:
        pass
    return -1.0


class SnapshotFlag:
    """
    One-shot flag set by POST /snapshot (key-authenticated) and consumed by
    GET /frame.jpg via the X-Snapshot-Pending response header.

    The flag is cleared as part of the GET /frame.jpg response so the agent
    sees it without an extra round-trip.  Thread-safe.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._pending = False

    def set(self) -> None:
        with self._lock:
            self._pending = True

    def consume(self) -> bool:
        """Return True and clear the flag, or return False if not set."""
        with self._lock:
            if self._pending:
                self._pending = False
                return True
            return False

    def peek(self) -> bool:
        with self._lock:
            return self._pending


class FrameStore:
    """Holds ONLY the latest JPEG."""

    def __init__(self):
        self._lock = threading.Lock()
        self._jpeg: bytes | None = None
        self._at = 0.0

    def put(self, jpeg: bytes) -> None:
        with self._lock:
            self._jpeg, self._at = jpeg, time.monotonic()

    def get(self) -> tuple[bytes | None, float]:
        with self._lock:
            if self._jpeg is None:
                return None, float("inf")
            return self._jpeg, time.monotonic() - self._at


class CameraReader(threading.Thread):
    """ONE RTSP connection.  Decodes every frame, JPEG-encodes at most every ENCODE_INTERVAL_SEC."""

    def __init__(self, store: FrameStore, stop: threading.Event):
        super().__init__(name="camera-reader", daemon=True)
        self.store, self.stop = store, stop

    def _open(self):
        try:
            url = fetch_rtsp_url()
        except PlaceholderCameraUrl as exc:
            log.error("%s", exc)
            return None
        except Exception as exc:  # noqa: BLE001
            log.warning("cannot fetch RTSP URL from Vault: %s", exc)
            return None
        host = url_host(url)
        cap = cv2.VideoCapture(url, cv2.CAP_FFMPEG, [
            cv2.CAP_PROP_OPEN_TIMEOUT_MSEC, 5000,
            cv2.CAP_PROP_READ_TIMEOUT_MSEC, 5000,
        ])
        del url
        if not cap.isOpened():
            log.warning("RTSP open failed (host %s)", host)
            cap.release()
            return None
        log.info("RTSP connected (host %s, %dx%d)", host,
                 int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT)))
        return cap

    def run(self) -> None:
        backoff = 1.0
        while not self.stop.is_set():
            cap = self._open()
            if cap is None:
                self.stop.wait(backoff)
                backoff = min(backoff * 2, 30.0)
                continue
            backoff = 1.0
            self._pump(cap)
            cap.release()
            log.warning("RTSP stream lost — reconnecting")

    def _pump(self, cap) -> None:
        last_encode = 0.0
        grabbed = encoded = 0
        w_start, cpu_start = time.monotonic(), time.thread_time()
        fails = 0
        while not self.stop.is_set():
            if not cap.grab():
                fails += 1
                if fails >= 5:
                    return
                time.sleep(0.2)
                continue
            fails = 0
            grabbed += 1
            now = time.monotonic()
            if now - last_encode >= ENCODE_INTERVAL_SEC:
                ok, frame = cap.retrieve()
                if ok and frame is not None:
                    h, w = frame.shape[:2]
                    if w > MAX_WIDTH:
                        frame = cv2.resize(frame, (MAX_WIDTH, int(h * MAX_WIDTH / w)),
                                           interpolation=cv2.INTER_AREA)
                    ok, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, JPEG_QUALITY])
                    if ok:
                        self.store.put(buf.tobytes())
                        encoded += 1
                        last_encode = now
            if now - w_start >= STATS_INTERVAL_SEC:
                cpu = time.thread_time() - cpu_start
                wall = now - w_start
                log.info("reader stats: thread_cpu=%.1f%% of one core, process_rss=%.0f MB, "
                         "grabbed=%d (%.1f fps), jpeg_encoded=%d",
                         100.0 * cpu / wall, _vm_rss_mb(), grabbed, grabbed / wall, encoded)
                w_start, cpu_start, grabbed, encoded = now, time.thread_time(), 0, 0


# ── Rate limiting ────────────────────────────────────────────────────────────

class RateLimiter:
    """Token bucket per key.  Bounded: when full of live buckets, new keys are refused."""

    def __init__(self, burst: int, per_sec: float, max_keys: int = 1024):
        self.burst, self.per_sec, self.max_keys = burst, per_sec, max_keys
        self._b: dict[str, tuple[float, float]] = {}
        self._lock = threading.Lock()

    def allow(self, key: str) -> bool:
        now = time.monotonic()
        with self._lock:
            tokens, last = self._b.get(key, (float(self.burst), now))
            if key not in self._b and len(self._b) >= self.max_keys:
                self._b = {k: v for k, v in self._b.items() if now - v[1] < 60}
                if len(self._b) >= self.max_keys:
                    return False
            tokens = min(self.burst, tokens + (now - last) * self.per_sec)
            if tokens < 1.0:
                self._b[key] = (tokens, now)
                return False
            self._b[key] = (tokens - 1.0, now)
            return True


# ── Event pipeline: encrypt + INSERT ─────────────────────────────────────────

class EventWriter:
    def __init__(self):
        self._lock = threading.Lock()
        self._dek: DataKey | None = None
        self._cred: DbCredential | None = None
        self._rows = 0                      # successful INSERTs since process start (written under _lock)
        self._rotate_lock = threading.Lock()  # one rotation at a time; NOT the INSERT lock

    def warm_up(self) -> None:
        with self._lock:
            self._dek = request_datakey()
            self._cred = request_db_cred()

    # ── Session 5-5e: background renewal (reads and idle periods no longer depend on an agent write) ──
    def start_refresher(self, stop: threading.Event) -> None:
        def _loop() -> None:
            while not stop.wait(CRED_CHECK_INTERVAL_SEC):
                try:
                    self._renew_if_due()
                except Exception as exc:  # noqa: BLE001
                    log.warning("background credential renewal failed: %s", type(exc).__name__)
        threading.Thread(target=_loop, name="cred-refresher", daemon=True).start()

    def _renew_if_due(self) -> None:
        """Same swap/revoke order as rotate(): fresh lease outside the INSERT lock, swap, revoke the old one."""
        with self._lock:
            c = self._cred
        if c is not None and not c.needs_refresh():
            return
        if not self._rotate_lock.acquire(blocking=False):   # a manual rotation is running: it renews anyway
            return
        try:
            fresh = request_db_cred()
            if fresh is None:
                return                                      # request_db_cred() already logged the reason
            with self._lock:
                old, self._cred = self._cred, fresh
            if old is None or not old.lease_id:
                revoked, why = False, "no previous lease"
            elif old.expires_at <= time.monotonic():
                revoked, why = False, "previous lease already expired"
            else:
                revoked, why = revoke_db_lease(old.lease_id)
            log.info("credential renewed in background: old=%s new=%s revoked=%s (%s)",
                     old.username if old else None, fresh.username, revoked, why)
        finally:
            self._rotate_lock.release()

    # ── Session 5-3b: credential status / rotation / read-back (admin routes) ──
    def status(self) -> dict:
        """Username, remaining lease time and lease id of the ACTIVE credential.  Never the password."""
        with self._lock:
            c = self._cred
        if c is None:
            return {"db_username": None, "lease_ttl_s": 0, "lease_duration_s": 0, "lease_id": None,
                    "rows_written": self._rows}
        return {"db_username": c.username, "lease_ttl_s": max(0, int(c.expires_at - time.monotonic())),
                "lease_duration_s": c.lease_sec, "lease_id": c.lease_id, "rows_written": self._rows}

    def rotate(self) -> tuple[int, dict]:
        """Fresh lease -> swap -> revoke the old lease.

        The slow work (Vault read of the new credential, Vault revoke of the old one) runs OUTSIDE the
        INSERT lock, so POST /events keeps writing with the old credential until the swap and with the
        new one right after it.  The swap itself takes the INSERT lock, which means it waits for an
        INSERT that is already running (the old credential is therefore never revoked mid-INSERT)."""
        if not self._rotate_lock.acquire(blocking=False):
            return 409, {"error": "a rotation is already running"}
        try:
            rows_before = self._rows
            t0 = time.monotonic()
            fresh = request_db_cred()                      # network call, INSERT lock NOT held
            if fresh is None:
                return 502, {"error": "could not obtain a fresh database credential"}
            with self._lock:                               # swap: pointer assignment only
                old, self._cred = self._cred, fresh
                swapped_at_rows = self._rows
            swap_ms = int((time.monotonic() - t0) * 1000)
            revoked, why = (False, "no previous lease")
            if old is not None and old.lease_id:
                revoked, why = revoke_db_lease(old.lease_id)   # network call, INSERT lock NOT held
            window_ms = int((time.monotonic() - t0) * 1000)
            rows_in_window = self._rows - rows_before
            log.info("credential rotated: old=%s new=%s revoked=%s (%s) window=%d ms rows_in_window=%d",
                     old.username if old else None, fresh.username, revoked, why, window_ms, rows_in_window)
            return 200, {"old_username": old.username if old else None, "new_username": fresh.username,
                         "old_lease_revoked": revoked, "revoke_detail": why,
                         "rows_written_since_rotate": rows_in_window,
                         "rows_before_swap": swapped_at_rows - rows_before,
                         "rows_after_swap": self._rows - swapped_at_rows,
                         "rotate_window_ms": window_ms, "swap_ms": swap_ms}
        finally:
            self._rotate_lock.release()

    @staticmethod
    def _query_recent(cred: DbCredential, limit: int) -> list:
        import psycopg2
        conn = psycopg2.connect(host=DB_HOST, port=DB_PORT, dbname=DB_NAME, user=cred.username,
                                password=cred.password, connect_timeout=5)
        try:
            with conn, conn.cursor() as cur:
                cur.execute("SELECT id, occurred_at, event_type, state, raw_payload, encrypted_datakey "
                            "FROM events ORDER BY id DESC LIMIT %s", (limit,))
                return [{"id": r[0], "occurred_at": r[1].isoformat(), "event_type": r[2], "state": r[3],
                         "raw_payload": r[4], "encrypted_datakey": r[5]} for r in cur.fetchall()]
        finally:
            conn.close()

    def read_recent(self, limit: int) -> tuple[int, object]:
        """Newest stored events, CIPHERTEXT only.  Uses the active DB credential; holds no lock while querying.

        On psycopg2.OperationalError (credential gone, DB restarted ...) it retries ONCE with a freshly
        requested credential, which replaces the failed one (its lease is revoked, best effort)."""
        import psycopg2
        with self._lock:
            cred = self._cred
        if cred is None:
            return 503, "database credential unavailable"
        try:
            return 200, self._query_recent(cred, limit)
        except psycopg2.OperationalError as exc:
            log.warning("admin events read failed (%s), retrying once with a fresh credential",
                        type(exc).__name__)
        except Exception as exc:  # noqa: BLE001
            log.warning("admin events read failed: %s", type(exc).__name__)
            return 502, "database read failed"
        fresh = request_db_cred()
        if fresh is None:
            return 502, "database read failed"
        with self._lock:
            old, self._cred = self._cred, fresh
        if old is not None and old.lease_id and old.expires_at > time.monotonic():
            revoke_db_lease(old.lease_id)
        try:
            return 200, self._query_recent(fresh, limit)
        except Exception as exc:  # noqa: BLE001
            log.warning("admin events read failed after retry: %s", type(exc).__name__)
            return 502, "database read failed"

    def write(self, ev: dict) -> tuple[int, int | str]:
        """Return (http_status, row_id_or_error)."""
        import psycopg2
        with self._lock:
            if self._dek is None or self._dek.needs_refresh():
                fresh = request_datakey()
                if fresh is not None:
                    self._dek = fresh
                elif self._dek is not None and self._dek.needs_refresh():
                    self._dek = None
            if self._cred is None or self._cred.needs_refresh():
                fresh_c = request_db_cred()
                if fresh_c is not None:
                    self._cred = fresh_c
                elif self._cred is not None and self._cred.needs_refresh():
                    self._cred = None
            dek, cred = self._dek, self._cred
            if dek is None:
                return 503, "transit datakey unavailable"   # never store plaintext
            if cred is None:
                return 503, "database credential unavailable"
            encrypted = dek.encrypt(ev["raw_payload"])
            row_id = None
            for attempt in (1, 2):
                try:
                    conn = psycopg2.connect(host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
                                            user=cred.username, password=cred.password,
                                            connect_timeout=5)
                    try:
                        with conn, conn.cursor() as cur:
                            cur.execute(
                                "INSERT INTO events (camera_id, event_type, state, duration_s, warned, "
                                "raw_payload, encrypted_datakey) VALUES (%s,%s,%s,%s,%s,%s,%s) RETURNING id",
                                (CAMERA_ID, ev["event_type"], ev["state"], ev["duration_s"],
                                 ev["warned"], encrypted, dek.ciphertext),
                            )
                            row_id = cur.fetchone()[0]
                    finally:
                        conn.close()
                    break
                except psycopg2.OperationalError as exc:
                    # Class name only: driver messages may contain connection details.
                    log.warning("DB insert failed (%s/%s): %s (attempt %d)", ev["event_type"], ev["state"],
                                type(exc).__name__, attempt)
                    if attempt == 2:
                        return 502, "database write failed"
                    # Session 5-5e: retry ONCE with a fresh credential; the failed one is NOT dropped on a
                    # plain connection error (the old lease is left to expire: we hold the INSERT lock here).
                    fresh_c = request_db_cred()
                    if fresh_c is None:
                        return 502, "database write failed"
                    self._cred = cred = fresh_c
                except Exception as exc:  # noqa: BLE001
                    log.warning("DB insert failed (%s/%s): %s", ev["event_type"], ev["state"],
                                type(exc).__name__)
                    return 502, "database write failed"
            self._rows += 1
            log.info("event stored: id=%s type=%s state=%s",
                     row_id, ev["event_type"], ev["state"])
            return 201, row_id


def validate_event(raw: bytes) -> tuple[dict | None, str]:
    try:
        doc = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        return None, "body is not valid JSON"
    if not isinstance(doc, dict):
        return None, "body must be a JSON object"
    try:
        extra = set(doc) - EVENT_FIELDS
        if extra:
            return None, "unknown field(s)"
        if doc.get("event_type") not in EVENT_TYPES:
            return None, "event_type not in allow-list"
        if doc.get("state") not in EVENT_STATES:
            return None, "state not in allow-list"
        payload = doc.get("raw_payload")
        if not isinstance(payload, str) or not payload or len(payload) > MAX_PAYLOAD_CHARS:
            return None, f"raw_payload must be a non-empty string up to {MAX_PAYLOAD_CHARS} chars"
        dur = doc.get("duration_s")
        if dur is not None:
            if isinstance(dur, bool) or not isinstance(dur, (int, float)) or not 0 <= dur <= 10**7:
                return None, "duration_s must be a number 0..10000000 or null"
            dur = int(dur)
        warned = doc.get("warned", False)
        if not isinstance(warned, bool):
            return None, "warned must be a boolean"
        return {"event_type": doc["event_type"], "state": doc["state"], "raw_payload": payload,
                "duration_s": dur, "warned": warned}, ""
    except (TypeError, ValueError, KeyError):
        return None, "invalid field structure or type in payload"


# ── HTTP server ──────────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    server_version = "trusted-edge"
    sys_version = ""
    timeout = 30                       # slow-client guard (10 was too tight for sandbox exec cold-start)

    # Set by main() before serving.
    key_hash: str = ""
    admin_key_hash: str = ""            # "" = admin key not provisioned -> /admin/* answers 503
    frames: FrameStore
    snapshot: SnapshotFlag
    writer: EventWriter
    events_rl    = RateLimiter(*EVENTS_LIMIT)
    frame_rl     = RateLimiter(*FRAME_LIMIT)
    authfail_rl  = RateLimiter(*AUTHFAIL_LIMIT)
    snapshot_rl  = RateLimiter(*SNAPSHOT_LIMIT)
    admin_rl     = RateLimiter(*ADMIN_LIMIT)
    rotate_rl    = RateLimiter(*ROTATE_LIMIT)

    def log_message(self, fmt, *args):          # no request line / headers in the journal
        pass

    def _log_req(self, status: int) -> None:
        # method, path, status and source address only.  Headers (incl. X-Edge-Key) are never logged.
        log.info("req client=%s:%s %s %s -> %s", self.client_address[0], self.client_address[1],
                 self.command, self.path[:64], status)

    def _send(self, status: int, body: bytes = b"", ctype: str = "application/json",
              extra: dict | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)
        self._log_req(status)

    def _json(self, status: int, obj: dict) -> None:
        self._send(status, json.dumps(obj).encode())

    def _authenticate(self) -> bool:
        """True if the key is valid.  Sends 401/429 itself otherwise."""
        presented = hashlib.sha256(self.headers.get("X-Edge-Key", "").encode()).hexdigest()
        if hmac.compare_digest(presented, self.key_hash):
            return True
        if not self.authfail_rl.allow(self.client_address[0]):
            self._json(429, {"error": "too many failed attempts"})
        else:
            self._json(401, {"error": "unauthorized"})
        return False

    def _authenticate_admin(self) -> bool:
        """True if X-Admin-Key is valid.  Sends 503/401/429 itself otherwise.  The ingest key never matches."""
        if not self.admin_key_hash:
            self._json(503, {"error": "admin key not provisioned"})
            return False
        presented = hashlib.sha256(self.headers.get("X-Admin-Key", "").encode()).hexdigest()
        if hmac.compare_digest(presented, self.admin_key_hash):
            if not self.admin_rl.allow(self.admin_key_hash):
                self._json(429, {"error": "rate limit"})
                return False
            return True
        if not self.authfail_rl.allow(self.client_address[0]):
            self._json(429, {"error": "too many failed attempts"})
        else:
            self._json(401, {"error": "unauthorized"})
        return False

    def _admin_get(self, route: str, query: str) -> None:
        if not self._authenticate_admin():
            return
        if route == "/admin/credential":
            return self._json(200, self.writer.status())
        if route == "/admin/identity":
            try:
                d = _vault_get("auth/token/lookup-self", token=_vault_token()).get("data", {})
            except Exception as exc:  # noqa: BLE001
                return self._json(502, {"error": f"lookup-self failed: {type(exc).__name__}"})
            # Whitelist: the token id is never returned.
            return self._json(200, {k: d.get(k) for k in ("display_name", "policies", "ttl", "expire_time", "path")})
        if route == "/admin/events":
            limit = 10
            for part in query.split("&"):
                if part.startswith("limit="):
                    try:
                        limit = int(part[6:])
                    except ValueError:
                        return self._json(400, {"error": "limit must be an integer"})
            limit = max(1, min(limit, ADMIN_EVENTS_MAX))
            status, rows = self.writer.read_recent(limit)
            return self._json(status, {"events": rows} if status == 200 else {"error": rows})
        return self._json(404, {"error": "not found"})

    def do_GET(self):
        parts = urlsplit(self.path)
        if parts.path.startswith("/admin/"):
            return self._admin_get(parts.path, parts.query)
        if self.path == "/frame.jpg":
            if not self._authenticate():
                return
            if not self.frame_rl.allow(self.key_hash):
                return self._json(429, {"error": "rate limit"})
            jpeg, age = self.frames.get()
            if jpeg is None or age > FRAME_STALE_SEC:
                return self._json(503, {"error": "no fresh frame"})
            # Piggyback the snapshot flag on the frame response so the agent
            # learns about it without an extra round-trip.  The flag is consumed
            # (cleared) atomically here; if the frame is stale we do NOT consume
            # it (the agent can't use a stale frame for a snapshot anyway).
            pending = self.snapshot.consume()
            extra = {"X-Frame-Age-Ms": str(int(age * 1000))}
            if pending:
                extra["X-Snapshot-Pending"] = "1"
            return self._send(200, jpeg, "image/jpeg", extra)

        return self._json(404, {"error": "not found"})

    def _read_event_body(self) -> bytes | None:
        """Read and size-check a JSON body.  Sends 411/400/413 itself and returns None on failure."""
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            self._json(411, {"error": "Content-Length required"})
            return None
        if length < 0:
            self._json(400, {"error": "bad Content-Length"})
            return None
        if length > MAX_BODY_BYTES:
            # Drain a bounded amount so the client reads the 413 instead of a connection reset.
            left = min(length, 1 << 20)
            while left > 0:
                chunk = self.rfile.read(min(left, 65536))
                if not chunk:
                    break
                left -= len(chunk)
            self._json(413, {"error": "body too large"})
            return None
        return self.rfile.read(length)

    def do_POST(self):
        if self.path == "/admin/events":
            if not self._authenticate_admin():
                return
            if not self.events_rl.allow(self.admin_key_hash):
                return self._json(429, {"error": "rate limit"})
            raw = self._read_event_body()
            if raw is None:
                return
            ev, err = validate_event(raw)
            if ev is None:
                return self._json(422, {"error": err})
            if ev["event_type"] != MANUAL_EVENT_TYPE:
                return self._json(422, {"error": f"this route only stores event_type {MANUAL_EVENT_TYPE}"})
            status, result = self.writer.write(ev)
            return self._json(status, {"id": result} if status == 201 else {"error": result})

        if self.path == "/admin/rotate-credential":
            if not self._authenticate_admin():
                return
            if not self.rotate_rl.allow(self.admin_key_hash):
                return self._json(429, {"error": "rate limit"})
            status, body = self.writer.rotate()
            return self._json(status, body)

        if self.path == "/snapshot":
            # Remote manual trigger: force the agent to run inference on the
            # next frame fetch regardless of the motion MAD.
            if not self._authenticate():
                return
            if not self.snapshot_rl.allow(self.key_hash):
                return self._json(429, {"error": "rate limit"})
            self.snapshot.set()
            log.info("snapshot trigger set by %s:%s", self.client_address[0], self.client_address[1])
            return self._json(200, {"triggered": True})

        if self.path != "/events":
            return self._json(404, {"error": "not found"})
        if not self._authenticate():
            return
        if not self.events_rl.allow(self.key_hash):
            return self._json(429, {"error": "rate limit"})
        raw = self._read_event_body()
        if raw is None:
            return
        try:
            ev, err = validate_event(raw)
            if ev is None:
                return self._json(422, {"error": err})
            if ev["event_type"] == MANUAL_EVENT_TYPE:
                return self._json(422, {"error": "event_type not allowed on this route"})
            status, result = self.writer.write(ev)
            self._json(status, {"id": result} if status == 201 else {"error": result})
        except Exception as exc:  # noqa: BLE001
            log.error("error processing event: %s", exc)
            self._json(500, {"error": "internal error processing event"})

    def _not_found(self):
        self._json(404, {"error": "not found"})

    do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = do_CONNECT = _not_found


# ── main ─────────────────────────────────────────────────────────────────────

def main() -> int:
    logging.basicConfig(level=logging.INFO, format="[trusted-edge] %(levelname)s %(message)s",
                        stream=sys.stderr)
    log.info("starting (python %s, uid %d)", sys.version.split()[0], os.getuid())
    log.info("bind=%s:%d vault=%s token_file=%s db=%s:%d/%s",
             BIND_ADDR, BIND_PORT, VAULT_ADDR, VAULT_TOKEN_FILE, DB_HOST, DB_PORT, DB_NAME)

    try:
        key_hash = load_ingest_key_hash()
    except Exception as exc:  # noqa: BLE001
        log.error("cannot load ingest-key hash from Vault (%s): %s", INGEST_KV_PATH, exc)
        return 2
    try:
        url = fetch_rtsp_url()
    except PlaceholderCameraUrl as exc:
        log.error("REFUSING TO START: %s", exc)
        return 3
    except Exception as exc:  # noqa: BLE001
        log.error("cannot fetch RTSP URL from Vault: %s", exc)
        return 2
    log.info("camera URL present in Vault, not a placeholder (host %s)", url_host(url))
    del url

    # Admin key hash (Session 5-3b).  Absent = /admin/* answers 503; the ingest path is unaffected.
    admin_hash = ""
    try:
        admin_hash = load_key_hash(ADMIN_KV_PATH)
        log.info("admin key hash loaded from Vault (%s): /admin/* enabled", ADMIN_KV_PATH)
    except Exception as exc:  # noqa: BLE001
        status = getattr(getattr(exc, "response", None), "status_code", None)
        log.warning("admin key hash NOT loaded (%s%s): /admin/* disabled (503)", type(exc).__name__,
                    f" HTTP {status}" if status else "")

    stop = threading.Event()
    frames, writer, snapshot = FrameStore(), EventWriter(), SnapshotFlag()
    writer.warm_up()
    writer.start_refresher(stop)
    Handler.key_hash, Handler.frames, Handler.writer, Handler.snapshot = \
        key_hash, frames, writer, snapshot
    Handler.admin_key_hash = admin_hash

    CameraReader(frames, stop).start()
    httpd = ThreadingHTTPServer((BIND_ADDR, BIND_PORT), Handler)
    httpd.daemon_threads = True

    def _term(signum, _frame):
        log.info("signal %d — shutting down", signum)
        stop.set()
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _term)
    signal.signal(signal.SIGINT, _term)
    log.info("listening on %s:%d (GET /frame.jpg, POST /events, POST /snapshot, /admin/* %s)",
             BIND_ADDR, BIND_PORT, "enabled" if admin_hash else "disabled")
    httpd.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
