# vault/policies/edge-agent-policy.hcl
# ACL policy for the Camera Edge Agent (TPM role edge-camera-agent, consumer: trusted-edge).
#
# Least-privilege: read dynamic DB credentials, request a Transit datakey for local
# AES-256-GCM envelope encryption, read KV-v2 camera RTSP URL, and renew/lookup own token.
#
# NOT granted: Transit encrypt/decrypt paths (nothing in trusted-edge calls them;
# decrypt for read-back belongs to a separate control-plane reader — Session 5-3).
# NOT granted: edge-ai-demo-gateway/ (gateway role only).
# NOT granted: sys/ (no admin paths).

# ── Dynamic Database Credentials ─────────────────────────────────────────────
# The edge agent requests a short-lived Postgres credential (5 m / 10 m TTL).
path "edge-ai-demo-database/creds/edge-camera-agent" {
  capabilities = ["read"]
}

# ── Transit Datakey ───────────────────────────────────────────────────────────
# Request an ephemeral datakey for local AES-256-GCM envelope encryption.
# This eliminates per-frame network round-trips to Vault.
# encrypt/decrypt are intentionally omitted — the agent never calls them.
path "edge-ai-demo-encryption-transit/datakey/plaintext/edge-telemetry" {
  capabilities = ["update"]
}

# ── KV-v2 Static Secrets ──────────────────────────────────────────────────────
# Camera RTSP URL.
path "edge-ai-demo-kv/data/edge-device/camera-creds" {
  capabilities = ["read"]
}

# Admin-key hash (Session 5-3b): same create+read-only scheme as the ingest-key hash below.
# trusted-edge authenticates /admin/* (credential status, rotate, identity, stored-event ciphertext)
# with this key; the WebUI holds the plaintext via systemd LoadCredential=.
path "edge-ai-demo-kv/data/edge-device/admin-key" {
  capabilities = ["create", "read"]
}

# Ingest-key hash (Session 3-5g): the stage writes SHA-256(key) once, trusted-edge
# reads it to authenticate X-Edge-Key. create+read only: a second write, delete and
# metadata delete are denied (verified with a throw-away token, Session 3-5g), so a
# compromised edge token cannot replace the hash. Rotation = root-side delete on the Mac.
path "edge-ai-demo-kv/data/edge-device/ingest-key" {
  capabilities = ["create", "read"]
}

# KV-v2 metadata (required to list / check secret versions).
path "edge-ai-demo-kv/metadata/edge-device/*" {
  capabilities = ["read", "list"]
}

# ── Lease revoke for "Rotate Secret Now" (Session 5-3b) ───────────────────────
# trusted-edge revokes the OLD dynamic DB lease after swapping to a fresh one.
# Path-parameter form of POST /v1/sys/leases/revoke/:lease_id, scoped to leases of THIS DB role only.
# NOT granted: sys/leases/revoke (body form), revoke-prefix, revoke-force, lookup, any other prefix.
path "sys/leases/revoke/edge-ai-demo-database/creds/edge-camera-agent/*" {
  capabilities = ["update"]
}

# ── Token Self-Management ─────────────────────────────────────────────────────
# Allow the agent to renew its own token.
path "auth/token/renew-self" {
  capabilities = ["update"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

# ── TPM Auth (Phase 5) ────────────────────────────────────────────────────────
# Allow the edge agent to authenticate via auth/tpm and read its own identity.
path "auth/tpm/login" {
  capabilities = ["create", "update"]
}

# Allow Vault Agent to look up its own TPM-issued token (for renewal/re-auth).
path "auth/tpm/role/edge-camera-agent" {
  capabilities = ["read"]
}
