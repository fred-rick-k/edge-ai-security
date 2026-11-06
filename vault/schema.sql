-- vault/schema.sql
-- PostgreSQL schema for the Edge Device Security Demo.
-- Applied automatically by postgres:16 on first container start
-- (mounted at /docker-entrypoint-initdb.d/schema.sql).
--
-- raw_payload in events holds Vault Transit ciphertext (vault:v1:...)
-- — never plaintext inference output.

-- ── Captured frames ───────────────────────────────────────────────────────────
-- File-path references only; raw bytes are NOT stored in the database.
CREATE TABLE IF NOT EXISTS frames (
    id          SERIAL PRIMARY KEY,
    captured_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    camera_id   TEXT        NOT NULL,   -- e.g. 'cam-garage', 'cam-gate'
    file_path   TEXT        NOT NULL,   -- absolute path to JPEG on Jetson local storage
    width       INTEGER,
    height      INTEGER
);

CREATE INDEX IF NOT EXISTS idx_frames_camera_id   ON frames (camera_id);
CREATE INDEX IF NOT EXISTS idx_frames_captured_at ON frames (captured_at DESC);

-- ── Inference events ──────────────────────────────────────────────────────────
-- One row per detection derived from a frame.
-- raw_payload is stored as Vault Transit ciphertext so no plaintext inference
-- data is ever written to disk.
CREATE TABLE IF NOT EXISTS events (
    id               SERIAL PRIMARY KEY,
    occurred_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    camera_id        TEXT        NOT NULL,  -- e.g. 'cam-garage', 'cam-gate'
    event_type       TEXT        NOT NULL,  -- 'gate_open', 'person', 'package_appeared', …
    state            TEXT,                  -- 'open', 'closed', 'present', 'absent'
    duration_s       INTEGER,               -- seconds open so far (timed-open events)
    warned           BOOLEAN     NOT NULL DEFAULT FALSE,
    confidence       FLOAT,                 -- model confidence score 0.0–1.0
    frame_id         INTEGER     REFERENCES frames (id) ON DELETE SET NULL,
    raw_payload      TEXT,                  -- AES-256-GCM encrypted payload (base64)
    encrypted_datakey TEXT                  -- Vault Transit ciphertext wrapping the DEK: vault:v1:…
);

CREATE INDEX IF NOT EXISTS idx_events_camera_id   ON events (camera_id);
CREATE INDEX IF NOT EXISTS idx_events_occurred_at ON events (occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_events_event_type  ON events (event_type);
