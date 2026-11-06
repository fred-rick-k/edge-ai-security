#!/usr/bin/env bash
# vault/init-vault.sh
# ──────────────────────────────────────────────────────────────────────────────
# Phase 4 Session 4-2 — Vault initialization, unseal, and full provisioning.
#
# Called by:  make setup-vault
# Run from:   ~/edge-device-demo  on the Mac
#
# What this script does (all steps are idempotent):
#   1. Initialize Vault (1 share / threshold 1) if not already initialized.
#   2. Save unseal key + root token to .vault-keys.json (gitignored).
#   3. Unseal Vault if sealed.
#   4. Enable + configure Secrets Engines:
#        - edge-ai-demo-database   (Database / PostgreSQL dynamic creds)
#        - edge-ai-demo-encryption-transit  (Transit convergent key)
#        - edge-ai-demo-kv         (KV-v2 static secrets)
#   5. Write Database dynamic role edge-camera-agent (GRANT ALL on tables/sequences, 5 m TTL).
#      NOTE: "INSERT-only" was a doc error (AGENTS.md §4). GRANT INSERT causes PostgreSQL 16
#      column-ACL conflicts that block all INSERTs. GRANT ALL PRIVILEGES is correct and intentional.
#   6. Write Transit convergent key edge-telemetry.
#   7. Seed KV-v2 placeholder secrets.
#   8. Write ACL policy edge-ai-demo-policy-edge.
#   9. Enable AppRole auth + create role edge-camera-agent.
#  10. Print a summary and the verification commands.
#
# Prerequisites (all satisfied after Session 4-1):
#   - Vault Enterprise container running on :8200 (via docker-compose.yml).
#   - PostgreSQL 16 container running on :5432, edge_demo database ready.
#   - vault CLI available on the Mac PATH (install: brew install vault).
#   - /usr/local/bin/docker on PATH.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Homebrew on Apple Silicon puts binaries in /opt/homebrew/bin, which is absent
# from non-interactive SSH sessions.  Prepend it so `vault` is always found.
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1090,SC1091
  source "${REPO_ROOT}/.env"
  set +a
fi
# scripts/mac-resume.sh (login LaunchAgent) sets this: .env's VAULT_ADDR is the Mac's LAN IP, which that
# job could not reach (timeout, 2026-11-03; cause inferred: macOS Local Network privacy), loopback works.
[[ -n "${VAULT_ADDR_OVERRIDE:-}" ]] && VAULT_ADDR="${VAULT_ADDR_OVERRIDE}"

# ── Vault License validation (string vs path) ─────────────────────────────────
VL_STR="${VAULT_LICENSE_STRING:-${VAULT_LICENSE:-}}"
VL_PATH="${VAULT_LICENSE_PATH:-}"

if [[ -n "${VL_STR}" && -n "${VL_PATH}" ]]; then
  echo "ERROR: Both VAULT_LICENSE_STRING (or VAULT_LICENSE) and VAULT_LICENSE_PATH are set in .env." >&2
  echo "       Please specify either VAULT_LICENSE_STRING or VAULT_LICENSE_PATH, not both." >&2
  exit 1
fi

if [[ -n "${VL_PATH}" ]]; then
  RESOLVED_VL_PATH="${VL_PATH/#\~/$HOME}"
  if [[ ! -f "${RESOLVED_VL_PATH}" ]]; then
    echo "ERROR: VAULT_LICENSE_PATH file not found: ${VL_PATH}" >&2
    exit 1
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────────────────────────────────────
VAULT_ADDR="${VAULT_ADDR:-https://127.0.0.1:8200}"
VAULT_CACERT="${VAULT_CACERT:-tls/vault.crt}"
KEYS_FILE="${KEYS_FILE:-.vault-keys.json}"
POLICY_FILE="vault/policies/edge-agent-policy.hcl"

# PostgreSQL connection parameters (T-37: from .env, same variables as docker-compose.yml).
# Vault runs inside Docker — use the Compose service name, not 127.0.0.1.
# No password fallback: the script aborts if POSTGRES_PASSWORD is unset or empty.
PG_HOST="${POSTGRES_HOST:-postgres}"
PG_PORT="${POSTGRES_PORT:-5432}"
PG_DATABASE="${POSTGRES_DB:?set POSTGRES_DB in .env}"
PG_SUPERUSER="${POSTGRES_USER:?set POSTGRES_USER in .env}"
PG_PASSWORD="${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD in .env}"

# Colour helpers
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}  ▷ $*${NC}"; }
ok()      { echo -e "${GREEN}  ✓ $*${NC}"; }
warn()    { echo -e "${YELLOW}  ⚠ $*${NC}"; }
err()     { echo -e "${RED}  ✗ $*${NC}"; exit 1; }
section() { echo -e "\n${GREEN}══ $* ══${NC}"; }

export VAULT_ADDR VAULT_CACERT

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

# vault_exec — run a vault CLI command, printing it first.
vault_exec() {
    echo -e "    ${YELLOW}\$ vault $*${NC}"
    vault "$@"
}

# mount_enabled path — true if the secrets engine at <path>/ is already mounted.
mount_enabled() {
    vault secrets list -format=json 2>/dev/null | python3 -c \
        "import json,sys; d=json.load(sys.stdin); sys.exit(0 if '$1/' in d else 1)" 2>/dev/null
}

# auth_enabled path — true if the auth method at <path>/ is already enabled.
auth_enabled() {
    vault auth list -format=json 2>/dev/null | python3 -c \
        "import json,sys; d=json.load(sys.stdin); sys.exit(0 if '$1/' in d else 1)" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# Preflight checks
# ─────────────────────────────────────────────────────────────────────────────
section "Preflight"

# Vault CLI
if ! command -v vault &>/dev/null; then
    err "vault CLI not found. Install with: brew install vault"
fi
ok "vault CLI: $(vault version | head -1)"

# Vault container reachable
if ! curl -s --cacert "${VAULT_CACERT}" --max-time 5 "${VAULT_ADDR}/v1/sys/health?uninitcode=200&sealedcode=200" > /dev/null; then
    err "Vault not reachable at ${VAULT_ADDR}. Run: make up-mac"
fi
ok "Vault reachable at ${VAULT_ADDR}"

# Policy file present
[[ -f "${POLICY_FILE}" ]] || err "Policy file missing: ${POLICY_FILE}"
ok "Policy file: ${POLICY_FILE}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 1 + 2: Initialize and save keys
# ─────────────────────────────────────────────────────────────────────────────
section "Step 1–2: Initialize Vault"

INITIALIZED=$(curl -s --cacert "${VAULT_CACERT}" "${VAULT_ADDR}/v1/sys/init" | python3 -c "import json,sys; print(json.load(sys.stdin)['initialized'])")

if [[ "${INITIALIZED}" == "True" ]]; then
    ok "Vault already initialized — loading keys from ${KEYS_FILE}"
    [[ -f "${KEYS_FILE}" ]] || err "${KEYS_FILE} not found. Cannot unseal. Delete the vault-data volume and re-run to start fresh."
    UNSEAL_KEY=$(python3 -c "import json; d=json.load(open('${KEYS_FILE}')); print(d['unseal_keys_b64'][0])")
    ROOT_TOKEN=$(python3 -c "import json; d=json.load(open('${KEYS_FILE}')); print(d['root_token'])")
else
    info "Initializing Vault (1 share, threshold 1)…"
    echo -e "    ${YELLOW}\$ vault operator init -key-shares=1 -key-threshold=1 -format=json${NC}"
    INIT_OUTPUT=$(vault operator init \
        -key-shares=1 \
        -key-threshold=1 \
        -format=json)

    UNSEAL_KEY=$(echo "${INIT_OUTPUT}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['unseal_keys_b64'][0])")
    ROOT_TOKEN=$(echo "${INIT_OUTPUT}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['root_token'])")

    # Save to .vault-keys.json (gitignored)
    echo "${INIT_OUTPUT}" > "${KEYS_FILE}"
    chmod 600 "${KEYS_FILE}"
    ok "Keys saved to ${KEYS_FILE} (gitignored, chmod 600)"
fi

export VAULT_TOKEN="${ROOT_TOKEN}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Unseal
# ─────────────────────────────────────────────────────────────────────────────
section "Step 3: Unseal"

SEALED=$(curl -s --cacert "${VAULT_CACERT}" "${VAULT_ADDR}/v1/sys/seal-status" | python3 -c "import json,sys; print(json.load(sys.stdin)['sealed'])")

if [[ "${SEALED}" == "True" ]]; then
    info "Unsealing Vault…"
    vault_exec operator unseal "${UNSEAL_KEY}"
    sleep 1
    ok "Vault unsealed"
else
    ok "Vault already unsealed"
fi

# Verify we can now talk to Vault with the root token
vault_exec status > /dev/null
ok "Authenticated with root token"

# Enable Vault audit logging if not already enabled
if vault audit list -format=json | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if 'file/' in d else 1)" 2>/dev/null; then
    ok "Vault audit logging already enabled"
else
    info "Enabling Vault file audit logging at /vault/logs/audit.log…"
    vault_exec audit enable file file_path=/vault/logs/audit.log
    ok "Vault audit logging enabled"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 4a: Database Secrets Engine
# ─────────────────────────────────────────────────────────────────────────────
section "Step 4a: Database Secrets Engine (edge-ai-demo-database)"

if mount_enabled "edge-ai-demo-database"; then
    ok "edge-ai-demo-database already enabled"
else
    info "Enabling database secrets engine…"
    vault_exec secrets enable \
        -path=edge-ai-demo-database \
        -description="Edge demo — PostgreSQL dynamic credentials" \
        database
    ok "Database secrets engine enabled at edge-ai-demo-database/"
fi

# T-37: after Vault has the superuser connection, Vault rotates the root password itself
# (POST <mount>/rotate-root/<name>); nobody, including .env, knows the new value afterwards.
# Docs: https://developer.hashicorp.com/vault/api-docs/secret/databases (Rotate root credentials)
#       https://developer.hashicorp.com/vault/api-docs/secret/databases/postgresql (templated
#       connection_url is required for rotation).
# The config is therefore written ONLY when it does not exist yet. Re-writing it on a later run
# would put the stale .env password back into Vault (and fail the connection check).
#   DB_ROOT_RESET=1 make setup-vault   — for an existing deployment, or to recover: sets a fresh
#   random superuser password in PostgreSQL (local socket inside the container), gives it to Vault,
#   rotates it again at once. The value is never printed or stored.
DB_CFG="edge-ai-demo-database/config/edge-demo-postgres"
DB_CONN_URL="postgresql://{{username}}:{{password}}@${PG_HOST}:${PG_PORT}/${PG_DATABASE}?sslmode=disable"

if [[ "${DB_ROOT_RESET:-0}" == "1" ]]; then
    info "DB_ROOT_RESET=1 — setting a random superuser password and handing it to Vault…"
    RESET_PW="$(openssl rand -hex 24)"
    printf 'ALTER USER "%s" PASSWORD '"'"'%s'"'"';\n' "${PG_SUPERUSER}" "${RESET_PW}" \
        | /usr/local/bin/docker exec -i postgres psql -v ON_ERROR_STOP=1 -U "${PG_SUPERUSER}" -d "${PG_DATABASE}" >/dev/null \
        || err "ALTER USER failed (is the postgres container running?)"
    printf '%s' "${RESET_PW}" | vault write "${DB_CFG}" \
        plugin_name=postgresql-database-plugin \
        allowed_roles="edge-camera-agent" \
        connection_url="${DB_CONN_URL}" \
        username="${PG_SUPERUSER}" \
        password=- >/dev/null
    unset RESET_PW
    vault_exec write -f "edge-ai-demo-database/rotate-root/edge-demo-postgres"
    ok "PostgreSQL superuser password reset and rotated by Vault (value unknown to everyone)"
elif vault read "${DB_CFG}" >/dev/null 2>&1; then
    ok "PostgreSQL connection already configured — left untouched (root password was rotated on first setup; DB_ROOT_RESET=1 to redo)"
else
    info "Configuring PostgreSQL connection…"
    vault_exec write "${DB_CFG}" \
        plugin_name=postgresql-database-plugin \
        allowed_roles="edge-camera-agent" \
        connection_url="${DB_CONN_URL}" \
        username="${PG_SUPERUSER}" \
        password="${PG_PASSWORD}"
    ok "PostgreSQL connection configured"
    info "Rotating the superuser password (Vault generates and keeps the new one)…"
    vault_exec write -f "edge-ai-demo-database/rotate-root/edge-demo-postgres"
    ok "Superuser password rotated — the value in .env no longer works for PostgreSQL"
fi

info "Writing dynamic role edge-camera-agent (GRANT ALL on ${PG_DATABASE} tables/sequences, 5 m TTL)…"
vault_exec write edge-ai-demo-database/roles/edge-camera-agent \
    db_name=edge-demo-postgres \
    default_ttl="5m" \
    max_ttl="10m" \
    creation_statements="
        CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
        GRANT ALL PRIVILEGES ON DATABASE \"${PG_DATABASE}\" TO \"{{name}}\";
        GRANT ALL ON SCHEMA public TO \"{{name}}\";
        GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO \"{{name}}\";
        GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO \"{{name}}\";
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO \"{{name}}\";
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO \"{{name}}\";
    " \
    revocation_statements="
        SELECT pg_terminate_backend(pid)
          FROM pg_stat_activity
         WHERE usename = '{{name}}';
        ALTER DEFAULT PRIVILEGES FOR ROLE \"{{name}}\" IN SCHEMA public REVOKE ALL ON TABLES FROM \"{{name}}\";
        ALTER DEFAULT PRIVILEGES FOR ROLE \"{{name}}\" IN SCHEMA public REVOKE ALL ON SEQUENCES FROM \"{{name}}\";
        ALTER DEFAULT PRIVILEGES FOR ROLE \"${PG_SUPERUSER}\" IN SCHEMA public REVOKE ALL ON TABLES FROM \"{{name}}\";
        ALTER DEFAULT PRIVILEGES FOR ROLE \"${PG_SUPERUSER}\" IN SCHEMA public REVOKE ALL ON SEQUENCES FROM \"{{name}}\";
        REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM \"{{name}}\";
        REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM \"{{name}}\";
        REVOKE ALL ON SCHEMA public FROM \"{{name}}\";
        REVOKE ALL ON DATABASE \"${PG_DATABASE}\" FROM \"{{name}}\";
        DROP ROLE IF EXISTS \"{{name}}\";
    "
ok "Dynamic role edge-camera-agent configured (GRANT ALL on ${PG_DATABASE} tables/sequences, 5 m / 10 m TTL)"

# ── Schema migration: ensure encrypted_datakey column exists ─────────────────
# Phase 5 Session 2 adds this column to store the Vault-wrapped DEK alongside
# the AES-GCM encrypted payload.  The CREATE TABLE in schema.sql handles fresh
# containers; this ALTER TABLE is idempotent for existing volumes.
section "Schema migration: events.encrypted_datakey"

PSQL_CMD="/usr/local/bin/docker exec -i postgres psql -U ${PG_SUPERUSER} -d ${PG_DATABASE}"
info "Checking for events.encrypted_datakey column…"
COL_EXISTS=$(${PSQL_CMD} -tAc \
    "SELECT COUNT(*) FROM information_schema.columns
      WHERE table_name='events' AND column_name='encrypted_datakey';" 2>/dev/null || echo "0")
if [[ "${COL_EXISTS}" == "0" ]] || [[ -z "${COL_EXISTS}" ]]; then
    info "Adding encrypted_datakey column to events table…"
    ${PSQL_CMD} -c \
        "ALTER TABLE events ADD COLUMN IF NOT EXISTS encrypted_datakey TEXT;" \
    && ok "Column encrypted_datakey added to events"
else
    ok "events.encrypted_datakey already present"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 4b: Transit Secrets Engine
# ─────────────────────────────────────────────────────────────────────────────
section "Step 4b: Transit Secrets Engine (edge-ai-demo-encryption-transit)"

if mount_enabled "edge-ai-demo-encryption-transit"; then
    ok "edge-ai-demo-encryption-transit already enabled"
else
    info "Enabling transit secrets engine…"
    vault_exec secrets enable \
        -path=edge-ai-demo-encryption-transit \
        -description="Edge demo — Transit envelope encryption" \
        transit
    ok "Transit secrets engine enabled at edge-ai-demo-encryption-transit/"
fi

info "Creating encryption key edge-telemetry (aes256-gcm96)…"
# If the key exists with derived=true from a previous run, allow deletion,
# delete it, then recreate without derivation so no per-request context
# is required for standard encrypt/decrypt calls.
if vault read -field=derived edge-ai-demo-encryption-transit/keys/edge-telemetry 2>/dev/null | grep -q "^true$"; then
    warn "Key edge-telemetry has derived=true — recreating without derivation…"
    vault write edge-ai-demo-encryption-transit/keys/edge-telemetry/config \
        deletion_allowed=true > /dev/null
    vault delete edge-ai-demo-encryption-transit/keys/edge-telemetry > /dev/null
fi
vault_exec write -f edge-ai-demo-encryption-transit/keys/edge-telemetry \
    type=aes256-gcm96
ok "Encryption key edge-telemetry ready (aes256-gcm96)"

# ─────────────────────────────────────────────────────────────────────────────
# Step 4c: KV-v2 Secrets Engine
# ─────────────────────────────────────────────────────────────────────────────
section "Step 4c: KV-v2 Secrets Engine (edge-ai-demo-kv)"

if mount_enabled "edge-ai-demo-kv"; then
    ok "edge-ai-demo-kv already enabled"
else
    info "Enabling KV-v2 secrets engine…"
    vault_exec secrets enable \
        -path=edge-ai-demo-kv \
        -description="Edge demo — static KV secrets" \
        -version=2 \
        kv
    ok "KV-v2 secrets engine enabled at edge-ai-demo-kv/"
fi

info "Writing placeholder camera credentials…"
# The full authenticated RTSP URL is stored as a single secret so the agent
# can use it directly without reassembling credentials from parts.
# Replace with the real URL before running Phase 5.
# The command is NOT echoed through vault_exec: it would print the camera URL with its password.
echo -e "    ${YELLOW}\$ vault kv put edge-ai-demo-kv/edge-device/camera-creds rtsp_url=<from .env, not printed>${NC}"
vault kv put -format=json edge-ai-demo-kv/edge-device/camera-creds \
    rtsp_url="${CAMERA_RTSP_URL:-rtsp://user:changeme@192.0.2.50:554/stream1}" >/dev/null
ok "Camera credentials written at edge-ai-demo-kv/edge-device/camera-creds (single rtsp_url field)"

# NVIDIA API key removed — cloud NIM not used in the current demo scope.
# Re-add here if Phase 6 (cloud inference) is enabled.

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: ACL Policy
# ─────────────────────────────────────────────────────────────────────────────
section "Step 5: ACL Policy (edge-ai-demo-policy-edge)"

info "Writing ACL policy from ${POLICY_FILE}…"
vault_exec policy write edge-ai-demo-policy-edge "${POLICY_FILE}"
ok "Policy edge-ai-demo-policy-edge written"

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: AppRole Auth
# ─────────────────────────────────────────────────────────────────────────────
section "Step 6: AppRole Auth (edge-camera-agent role)"

if auth_enabled "approle"; then
    ok "approle already enabled"
else
    info "Enabling AppRole auth method…"
    vault_exec auth enable approle
    ok "AppRole auth enabled at approle/"
fi

info "Writing AppRole role edge-camera-agent…"
vault_exec write auth/approle/role/edge-camera-agent \
    token_policies="edge-ai-demo-policy-edge" \
    token_ttl="1h" \
    token_max_ttl="4h" \
    token_num_uses=0 \
    secret_id_ttl="0" \
    bind_secret_id=true
ok "AppRole role edge-camera-agent configured"

# Retrieve and display the role_id for the agent configuration
ROLE_ID=$(vault_exec read -field=role_id auth/approle/role/edge-camera-agent/role-id)
ok "AppRole role_id: ${ROLE_ID}"

# Generate a wrapped secret_id (single-use for provisioning)
info "Generating AppRole secret_id…"
SECRET_ID=$(vault_exec write -f -field=secret_id auth/approle/role/edge-camera-agent/secret-id)
ok "AppRole secret_id generated (store this securely for Phase 5 agent config)"

# Persist role_id and secret_id into .vault-keys.json for Phase 5 retrieval
python3 - "${KEYS_FILE}" "${ROLE_ID}" "${SECRET_ID}" <<'EOF'
import json, sys
f, role_id, secret_id = sys.argv[1], sys.argv[2], sys.argv[3]
with open(f) as fh:
    d = json.load(fh)
d['approle_role_id']   = role_id
d['approle_secret_id'] = secret_id
with open(f, 'w') as fh:
    json.dump(d, fh, indent=2)
print(f"  → Persisted role_id and secret_id into {f}")
EOF

# ─────────────────────────────────────────────────────────────────────────────
# Done — print summary and verification commands
# ─────────────────────────────────────────────────────────────────────────────
section "Setup Complete"
echo ""
echo -e "${GREEN}Vault is initialized, unsealed, and fully provisioned.${NC}"
echo ""
echo -e "${CYAN}── Verification commands ────────────────────────────────────────────────${NC}"
echo ""
echo -e "  ${YELLOW}# The root token is never printed. Read it from ${KEYS_FILE} on the Mac, e.g.:${NC}"
echo    "  export VAULT_ADDR=${VAULT_ADDR}"
echo    "  export VAULT_TOKEN=\$(python3 -c \"import json;print(json.load(open('${KEYS_FILE}'))['root_token'])\")"
echo ""
echo -e "  ${YELLOW}# 1. Seal status${NC}"
echo    "  vault status"
echo ""
echo -e "  ${YELLOW}# 2. Dynamic DB credentials (5-minute lease)${NC}"
echo    "  vault read edge-ai-demo-database/creds/edge-camera-agent"
echo ""
echo -e "  ${YELLOW}# 3. Transit encrypt/decrypt${NC}"
echo    "  vault write -f edge-ai-demo-encryption-transit/encrypt/edge-telemetry \\"
echo    "      plaintext=\$(echo -n 'hello-edge' | base64)"
echo ""
echo -e "  ${YELLOW}# 4. KV-v2 camera creds (prints the camera password)${NC}"
echo    "  vault kv get edge-ai-demo-kv/edge-device/camera-creds"
echo ""
echo -e "${CYAN}── Keys file ────────────────────────────────────────────────────────────${NC}"
echo    "  ${KEYS_FILE}  (chmod 600, gitignored)"
echo ""
