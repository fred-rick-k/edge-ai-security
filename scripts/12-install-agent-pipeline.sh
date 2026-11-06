#!/usr/bin/env bash
# scripts/12-install-agent-pipeline.sh
# ──────────────────────────────────────────────────────────────────────────────
# Phase 5 Session 2 — Stage 5-2: Transit envelope encryption + dynamic DB creds.
#
# What this script does:
#   1. Install agent Python dependencies into agent/.venv
#      (requests + Pillow from agent/requirements.txt; cryptography for the step-4 AES-GCM test only).
#   2. Verify the Vault token exists in /run/openshell-edge/vault-token.
#   3. Smoke-test the Transit datakey endpoint from the Jetson:
#        POST /v1/edge-ai-demo-encryption-transit/datakey/plaintext/edge-telemetry
#      → assert response contains vault:v1:... ciphertext.
#   4. Smoke-test the DB creds endpoint:
#        GET /v1/edge-ai-demo-database/creds/edge-camera-agent
#      → assert response contains username + password.
#   5. Verify the policy allows Vault port 8200 (grep rendered policy).
#   6. Import agent.py and check that the functions its loop uses exist (no network).
#   7. Mark stage complete: 12_agent_pipeline.
#
# Prerequisites:
#   - Stage 5-1 complete (11_tpm_agent marker): vault-agent running,
#     /run/openshell-edge/vault-token present (0640 root:edge-ingest).
#   - VAULT_ADDR and VAULT_CACERT injected by bootstrap-jetson.sh.
#
# Called via:
#   ./scripts/bootstrap-jetson.sh <ip> --only-stage 5-2
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${REPO_DIR}/.setup-state"
MARKER="${STATE_DIR}/12_agent_pipeline"

AGENT_DIR="${REPO_DIR}/agent"
VENV_DIR="${AGENT_DIR}/.venv"
PYTHON="${VENV_DIR}/bin/python3"

TOKEN_SINK="/run/openshell-edge/vault-token"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}  ▷ $*${NC}"; }
ok()      { echo -e "${GREEN}  ✓ $*${NC}"; }
warn()    { echo -e "${YELLOW}  ⚠ $*${NC}"; }
err()     { echo -e "${RED}  ✗ $*${NC}"; exit 1; }
section() { echo -e "\n${GREEN}══ $* ══${NC}"; }

sudocmd() { echo "${SUDO_PASS}" | sudo -S "$@"; }

# ── Idempotency ───────────────────────────────────────────────────────────────
if [[ -f "${MARKER}" ]]; then
    echo -e "${GREEN}Stage 5-2 already complete (marker exists). Skipping.${NC}"
    exit 0
fi
mkdir -p "${STATE_DIR}"

# ── Entry checks ──────────────────────────────────────────────────────────────
section "Entry Checks"

[[ -f "${STATE_DIR}/11_tpm_agent" ]] \
    || err "Stage 5-1 (11_tpm_agent) not complete. Run --only-stage 5-1 first."
ok "Stage 5-1 marker present"

sudocmd test -s "${TOKEN_SINK}" 2>/dev/null \
    || err "Vault token not found at ${TOKEN_SINK}. Is vault-agent running? Check: systemctl status vault-agent"
ok "Vault token present at ${TOKEN_SINK}"

: "${VAULT_ADDR:?VAULT_ADDR must be set (injected by bootstrap)}"
: "${VAULT_CACERT:?VAULT_CACERT must be set (injected by bootstrap)}"
[[ -f "${VAULT_CACERT}" ]] \
    || err "VAULT_CACERT file not found: ${VAULT_CACERT}"
ok "VAULT_CACERT: ${VAULT_CACERT}"

# Vault reachable and unsealed
curl -s --cacert "${VAULT_CACERT}" --max-time 5 "${VAULT_ADDR}/v1/sys/health" | \
    python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if not d.get('sealed') else 1)" \
    2>/dev/null || err "Vault at ${VAULT_ADDR} is not reachable or is sealed."
ok "Vault reachable and unsealed at ${VAULT_ADDR}"

export VAULT_ADDR VAULT_CACERT

# ── Step 1: Install agent Python venv ─────────────────────────────────────────
section "Step 1: Python venv + dependencies"

if [[ ! -d "${VENV_DIR}" ]]; then
    info "Creating virtualenv at ${VENV_DIR}…"
    python3 -m venv "${VENV_DIR}"
fi
ok "Venv: ${VENV_DIR}"

info "Installing agent/requirements.txt into venv…"
# Upgrade pip silently first so older Jetson pip versions don't stall on deps.
"${PYTHON}" -m pip install --upgrade pip --quiet
"${PYTHON}" -m pip install -r "${AGENT_DIR}/requirements.txt" --quiet
# Since Session 3-5i agent/requirements.txt holds only what agent.py needs (requests, Pillow). Step 4 below
# runs an AES-GCM round-trip with this venv's python, so `cryptography` is installed here for that test only
# (Session 7-2d: a fresh device failed step 2/4 because it was no longer installed by requirements.txt).
"${PYTHON}" -m pip install "cryptography>=42.0.0" --quiet
ok "Dependencies installed: requests, Pillow (agent/requirements.txt) + cryptography (step 4 test)"

# ── Step 2: Verify imports ────────────────────────────────────────────────────
section "Step 2: Import verification"

"${PYTHON}" - <<'PYCHECK'
import cryptography
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
import requests
import PIL
import base64, json, os, sys, time
print(f"  cryptography  {cryptography.__version__}")
print(f"  requests      {requests.__version__}")
print(f"  Pillow        {PIL.__version__}")
PYCHECK
ok "All imports verified"

# ── Step 3: Transit datakey smoke test ────────────────────────────────────────
section "Step 3: Transit datakey smoke test"

VAULT_TOKEN=$(sudocmd cat "${TOKEN_SINK}")

info "POST ${VAULT_ADDR}/v1/edge-ai-demo-encryption-transit/datakey/plaintext/edge-telemetry"
DATAKEY_RESPONSE=$(curl -s --cacert "${VAULT_CACERT}" \
    -X POST \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{}' \
    "${VAULT_ADDR}/v1/edge-ai-demo-encryption-transit/datakey/plaintext/edge-telemetry")

# Validate: must contain vault:v1: ciphertext and non-empty plaintext
DATAKEY_CT=$(echo "${DATAKEY_RESPONSE}" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('ciphertext','MISSING'))" \
    2>/dev/null || echo "MISSING")
DATAKEY_PT=$(echo "${DATAKEY_RESPONSE}" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('plaintext','MISSING'))" \
    2>/dev/null || echo "MISSING")

if [[ "${DATAKEY_CT}" != vault:v1:* ]]; then
    warn "Raw Vault response: ${DATAKEY_RESPONSE}"
    err "Transit datakey ciphertext did not start with vault:v1: — got: ${DATAKEY_CT}"
fi
[[ "${DATAKEY_PT}" != "MISSING" ]] && [[ -n "${DATAKEY_PT}" ]] \
    || err "Transit datakey plaintext missing from response."

ok "Datakey ciphertext received (${#DATAKEY_CT} chars, vault:v1: format; not printed)"
ok "Datakey plaintext length: $(echo -n "${DATAKEY_PT}" | wc -c) chars (base64)"

# ── Step 4: AES-256-GCM local encryption test ─────────────────────────────────
section "Step 4: AES-256-GCM local encryption test"

"${PYTHON}" - "${DATAKEY_PT}" <<'PYTEST'
import sys, base64, os
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

plaintext_b64 = sys.argv[1]
raw = base64.b64decode(plaintext_b64)
assert len(raw) == 32, f"Expected 32-byte DEK, got {len(raw)}"

aesgcm = AESGCM(raw)
nonce  = os.urandom(12)
msg    = b"gate open 00:01:23"
ct     = aesgcm.encrypt(nonce, msg, None)
dec    = aesgcm.decrypt(nonce, ct, None)
assert dec == msg, "AES-256-GCM round-trip failed"
print(f"  AES-256-GCM encrypt+decrypt OK — ciphertext len={len(ct)} bytes")
PYTEST
ok "AES-256-GCM local encrypt/decrypt round-trip passed"

# ── Step 5: Dynamic DB credentials smoke test ─────────────────────────────────
section "Step 5: Dynamic DB credentials smoke test"

info "GET ${VAULT_ADDR}/v1/edge-ai-demo-database/creds/edge-camera-agent"
DBCRED_RESPONSE=$(curl -s --cacert "${VAULT_CACERT}" \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "${VAULT_ADDR}/v1/edge-ai-demo-database/creds/edge-camera-agent")

DB_USER=$(echo "${DBCRED_RESPONSE}" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('username','MISSING'))" \
    2>/dev/null || echo "MISSING")
DB_PASS=$(echo "${DBCRED_RESPONSE}" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('password','MISSING'))" \
    2>/dev/null || echo "MISSING")
DB_TTL=$(echo "${DBCRED_RESPONSE}" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d.get('lease_duration','?'))" \
    2>/dev/null || echo "?")

[[ "${DB_USER}" != "MISSING" ]] && [[ -n "${DB_USER}" ]] \
    || err "Dynamic DB creds: username missing from response. Vault DB engine not configured? Response: ${DBCRED_RESPONSE}"
[[ "${DB_PASS}" != "MISSING" ]] && [[ -n "${DB_PASS}" ]] \
    || err "Dynamic DB creds: password missing from response."

ok "Dynamic DB credential issued: user=${DB_USER} TTL=${DB_TTL}s"
ok "Zero plaintext credentials on Jetson — password held only in test variable (never written to disk)"

# ── Step 6: (removed in Session 3-5j) ─────────────────────────────────────────
# It checked port 8200 in /etc/openshell/agent-policy.yaml, a file that no longer exists and a rule that
# no longer exists: since 3-5h the sandbox policy has no Vault rule (the agent never talks to Vault).

# ── Step 7: Agent import check ────────────────────────────────────────────────
# Rewritten in Session 7-2d. The old check imported DataKey / DbCredential / _vault_token, which agent.py has not
# had since Session 3-5i (it no longer touches Vault, the DB or the DEK); the check failed with AttributeError.
# Loading the module runs only its top-level code (main() is behind __main__), so this needs no network.
section "Step 7: Agent import check"

info "Importing agent/agent.py and checking the functions the loop uses (10 s timeout)…"
timeout 10 "${PYTHON}" -c "
import importlib.util
spec = importlib.util.spec_from_file_location('agent', '${AGENT_DIR}/agent.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
for name in ('fetch_frame', 'call_vlm', 'parse_events', 'post_event', 'main'):
    assert callable(getattr(m, name)), name + ' missing or not callable'
print('  agent.py functions: OK (fetch_frame, call_vlm, parse_events, post_event, main)')
" || err "agent/agent.py failed to import or lacks an expected function (output above)"
ok "agent.py imports clean"

# ── Mark complete ─────────────────────────────────────────────────────────────
touch "${MARKER}"

section "Stage 5-2 Complete"
echo ""
echo -e "${GREEN}Data pipeline verification summary:${NC}"
echo -e "  ${CYAN}Transit datakey:${NC}     obtained (vault:v1: format ✓)"
echo -e "  ${CYAN}AES-256-GCM:${NC}         round-trip encrypt/decrypt ✓"
echo -e "  ${CYAN}Dynamic DB user:${NC}     ${DB_USER} (TTL ${DB_TTL}s) ✓"
echo -e "  ${CYAN}Plaintext on disk:${NC}   not checked by this stage (7-2e: the earlier claim 'NONE' was asserted, never tested)"
echo -e "  ${CYAN}Vault address:${NC}       ${VAULT_ADDR}"
echo ""
echo -e "${YELLOW}Next step — run the agent and verify DB rows:${NC}"
echo "  # On Jetson:"
echo "  VAULT_ADDR=${VAULT_ADDR} VAULT_CACERT=${VAULT_CACERT} \\"
echo "    ${PYTHON} ${AGENT_DIR}/agent.py"
echo ""
echo "  # On Mac — check rows contain vault:v1: ciphertext:"
echo "  docker exec -it postgres sh -c 'psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -c \"SELECT event_type, state, left(raw_payload,40), length(encrypted_datakey) FROM events ORDER BY occurred_at DESC LIMIT 5;\"'"
echo ""
