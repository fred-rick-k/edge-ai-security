#!/usr/bin/env bash
# vault/setup-tpm-auth.sh
# ──────────────────────────────────────────────────────────────────────────────
# Phase 5 Session 1 — Mac-side: Configure auth/tpm + enroll Jetson TPM remotely.
#
# Called by:  make setup-tpm-auth
# Run from:   ~/edge-device-demo  on the Mac
#
# Architecture — operator (Mac) enrolls the device; NO credential on Jetson:
#
#   Mac (this script, root token)          Jetson
#   ────────────────────────────           ──────────────────────────────────────
#   1. Enable auth/tpm
#   2. Configure auth/tpm/config
#   3. Create identity/tpmgroup
#                                    ──→  tpm2_createek -G rsa (no Vault auth)
#                                    ←──  EK public key PEM
#   4. vault write identity/tpm            (Mac only, root token)
#      → tpm_id
#      add tpm_id to identity/tpmgroup
#      bind role tpmgroup_ids
#                                    ──→  vault tpm attest (NO TOKEN REQUIRED)
#                                         gentpmcert/begin + finish are unauthenticated
#                                         — protected by TPM hardware challenge only
#                                         vault agent (hardware-only forever)
#
# Key insight — vault tpm attest requires NO Vault token:
#   The gentpmcert/begin and gentpmcert/finish endpoints are unauthenticated.
#   They are protected by the TPM hardware challenge/response itself:
#   Vault encrypts a secret with the EK pubkey; only the TPM holding the
#   matching private key can decrypt it.  No token, no credential needed.
#   Verified: vault tpm attest succeeds with VAULT_TOKEN=dummy.
#
# Why this is the correct operator pattern (per HashiCorp docs):
#   https://developer.hashicorp.com/vault/docs/auth/tpm/tpm
#   "Run this on the client machine that has the TPM, using tpm2_createek from
#    tpm2-tools to fetch the EK."
#   The EK pubkey is public material — safe to pipe over SSH.
#   vault write identity/tpm works with vault CLI 2.1.2 — no vault tpm needed.
#   The root token NEVER leaves the Mac.
#
# Prerequisites (Phase 4 complete):
#   - Vault 2.2.0+ent running on :8200 (make up-mac + make setup-vault done).
#   - .vault-keys.json present with root token.
#   - Jetson reachable at JETSON_HOST over SSH (key the JETSON_SSH_KEY from .env).
#   - tpm2-tools installed on Jetson (tpm2_createek — confirmed present v5.6).
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1090,SC1091
  source "${REPO_ROOT}/.env"
  set +a
fi

# ─────────────────────────────────────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────────────────────────────────────
VAULT_ADDR="${VAULT_ADDR:-https://127.0.0.1:8200}"
VAULT_CACERT="${VAULT_CACERT:-tls/vault.crt}"
KEYS_FILE="${KEYS_FILE:-.vault-keys.json}"
JETSON_USER="${JETSON_USER:-jetson}"
JETSON_IP="${JETSON_IP:-192.0.2.20}"
JETSON_HOST="${JETSON_HOST:-${JETSON_USER}@${JETSON_IP}}"
_RAW_KEY="${JETSON_SSH_KEY:-${HOME}/.ssh/id_ed25519}"
JETSON_SSH_KEY="${_RAW_KEY/#\~/$HOME}"
TPMGROUP_NAME="orin-nano-devices"
ROLE_NAME="edge-camera-agent"
TPM_DEVICE="/dev/tpmrm0"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}  ▷ $*${NC}"; }
ok()      { echo -e "${GREEN}  ✓ $*${NC}"; }
warn()    { echo -e "${YELLOW}  ⚠ $*${NC}"; }
err()     { echo -e "${RED}  ✗ $*${NC}"; exit 1; }
section() { echo -e "\n${GREEN}══ $* ══${NC}"; }

export VAULT_ADDR VAULT_CACERT

# ─────────────────────────────────────────────────────────────────────────────
# Preflight
# ─────────────────────────────────────────────────────────────────────────────
section "Preflight"

command -v vault &>/dev/null || err "vault CLI not found. Install with: brew install hashicorp/tap/vault"
ok "vault CLI: $(vault version | head -1)"

curl -s --cacert "${VAULT_CACERT}" --max-time 5 "${VAULT_ADDR}/v1/sys/health" > /dev/null || \
    err "Vault not reachable at ${VAULT_ADDR}. Run: make up-mac && make setup-vault"

SEALED=$(curl -s --cacert "${VAULT_CACERT}" "${VAULT_ADDR}/v1/sys/seal-status" | \
    python3 -c "import json,sys; print(json.load(sys.stdin)['sealed'])")
[[ "${SEALED}" == "False" ]] || err "Vault is sealed. Run: make setup-vault"
ok "Vault unsealed"

[[ -f "${KEYS_FILE}" ]] || err "${KEYS_FILE} missing. Run: make setup-vault"
ROOT_TOKEN=$(python3 -c "import json; d=json.load(open('${KEYS_FILE}')); print(d['root_token'])")
export VAULT_TOKEN="${ROOT_TOKEN}"
ok "Root token loaded from ${KEYS_FILE}"

VAULT_VER=$(vault status -format=json | python3 -c "import json,sys; print(json.load(sys.stdin)['version'])")
ok "Vault version: ${VAULT_VER}"

# Check Jetson SSH reachability (needed for EK pubkey read in Step 4)
ssh -i "${JETSON_SSH_KEY}" \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 \
    -o BatchMode=yes \
    "${JETSON_HOST}" "true" 2>/dev/null || \
    err "Cannot reach Jetson at ${JETSON_HOST} with key ${JETSON_SSH_KEY}"
ok "Jetson reachable at ${JETSON_HOST}"

# Confirm tpm2-tools is on Jetson (needed for tpm2_createek)
JETSON_TPM2=$(ssh -i "${JETSON_SSH_KEY}" \
    -o StrictHostKeyChecking=accept-new \
    -o BatchMode=yes \
    "${JETSON_HOST}" "which tpm2_createek 2>/dev/null || echo not_found" 2>/dev/null || echo "not_found")
[[ "${JETSON_TPM2}" == *"not_found"* ]] && \
    err "tpm2_createek not found on Jetson. Install with: sudo apt-get install -y tpm2-tools"
ok "tpm2_createek found on Jetson: ${JETSON_TPM2}"

# ─────────────────────────────────────────────────────────────────────────────
# Helper: check if auth method is already enabled
# ─────────────────────────────────────────────────────────────────────────────
auth_enabled() {
    vault auth list -format=json 2>/dev/null | \
        python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if '$1/' in d else 1)" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Enable auth/tpm
# ─────────────────────────────────────────────────────────────────────────────
section "Step 1: Enable auth/tpm"

if auth_enabled "tpm"; then
    ok "auth/tpm already enabled"
else
    info "Enabling TPM auth method …"
    vault auth enable \
        -path=tpm \
        -description="Hardware TPM 2.0 attestation for edge devices (Jetson Orin)" \
        tpm
    ok "auth/tpm enabled"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Configure auth/tpm/config
# Source: demotpm.sh line 21: vault write -f auth/tpm/config
# Only CA/cert lifetime params — no tpm_device_path (that is device-side).
# ─────────────────────────────────────────────────────────────────────────────
section "Step 2: auth/tpm/config"

info "Writing TPM auth configuration …"
vault write auth/tpm/config \
    default_cert_ttl="24h" \
    ca_lifetime="87600h"
ok "auth/tpm/config written (ca_lifetime=10y, default_cert_ttl=24h)"

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Create identity/tpmgroup (empty — members added in Step 5)
#
# identity/tpmgroup is a TPM-native endpoint, entirely separate from
# identity/group.  We create it empty here so the role binding is valid
# before enrollment.  Step 5 adds this device's tpm_id as a member.
# ─────────────────────────────────────────────────────────────────────────────
section "Step 3: identity/tpmgroup '${TPMGROUP_NAME}'"

EXISTING_TPMGROUP_ID=$(vault read -field=id \
    "identity/tpmgroup/name/${TPMGROUP_NAME}" 2>/dev/null || true)

if [[ -n "${EXISTING_TPMGROUP_ID}" ]]; then
    ok "identity/tpmgroup '${TPMGROUP_NAME}' already exists (id=${EXISTING_TPMGROUP_ID})"
    TPM_GROUP_ID="${EXISTING_TPMGROUP_ID}"
else
    info "Creating empty identity/tpmgroup '${TPMGROUP_NAME}' …"
    TPM_GROUP_ID=$(vault write -field=id identity/tpmgroup \
        name="${TPMGROUP_NAME}")
    ok "identity/tpmgroup '${TPMGROUP_NAME}' created (id=${TPM_GROUP_ID})"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Operator enrolls TPM from Mac — root token never leaves Mac
#
# Per HashiCorp docs (https://developer.hashicorp.com/vault/docs/auth/tpm/tpm):
#   "Run this on the client machine that has the TPM, using tpm2_createek from
#    tpm2-tools to fetch the EK."
#   vault write identity/tpm tpm_ek_public_key="$(sudo tpm2_createek ...)"
#
# Flow:
#   1. SSH to Jetson — run tpm2_createek (tpm2-tools, no Vault auth needed)
#      → EK public key PEM piped to Mac (public material, safe to transmit)
#   2. Mac runs vault write identity/tpm with root token (plain Vault API write,
#      works with vault CLI 2.1.2 — no 'vault tpm' subcommand needed)
#      → tpm_id
# ─────────────────────────────────────────────────────────────────────────────
section "Step 4: Operator enrolls TPM from Mac (tpm2_createek + vault write identity/tpm)"

# jetson user is in the 'tss' group — can access /dev/tpmrm0 without sudo.
# Use ~/ek.* paths (user-owned) to avoid root ownership issues from prior sudo runs.
info "Reading EK pubkey from Jetson TPM via tpm2_createek (no Vault auth, no sudo) …"
EK_PEM=$(ssh -i "${JETSON_SSH_KEY}" \
    -o StrictHostKeyChecking=accept-new \
    -o BatchMode=yes \
    "${JETSON_HOST}" \
    'rm -f ~/ek.ctx ~/ek.pub ~/ek.pem && \
     tpm2_createek -G rsa -u ~/ek.pub -c ~/ek.ctx 2>/dev/null && \
     tpm2_readpublic -c ~/ek.ctx -f pem -o ~/ek.pem 2>/dev/null && \
     cat ~/ek.pem && \
     rm -f ~/ek.ctx ~/ek.pub ~/ek.pem' 2>/dev/null || true)

[[ -n "${EK_PEM}" ]] || err "tpm2_createek returned empty EK pubkey from Jetson."
ok "EK pubkey read from Jetson hardware (public material — safe to transmit)"

info "Enrolling EK in Vault identity store (Mac-side, root token stays on Mac) …"
# Idempotent: if already enrolled vault write returns 400; look up the existing record.
TPM_ID=$(vault write -field=id identity/tpm \
    tpm_ek_public_key="${EK_PEM}" 2>/dev/null || true)

if [[ -z "${TPM_ID}" ]]; then
    info "TPM already enrolled — deriving tpm_id from EK pubkey (openssl, no network call) …"
    # Per Vault docs: tpm_id = "sha256-" + hex(SHA256(DER(EK_pubkey)))
    # openssl is always available on macOS. This is deterministic and requires
    # no vault read loop — just re-derive from the EK PEM we already have.
    TPM_ID=$(echo "${EK_PEM}" | \
        openssl pkey -pubin -outform DER 2>/dev/null | \
        openssl dgst -sha256 -hex | \
        awk '{print "sha256-" $2}')
fi

[[ -n "${TPM_ID}" ]] || err "vault write identity/tpm returned empty id and lookup failed."
ok "TPM enrolled in identity store. tpm_id: ${TPM_ID}"

# Add tpm_id to identity/tpmgroup
info "Adding tpm_id to identity/tpmgroup '${TPMGROUP_NAME}' …"
vault write "identity/tpmgroup/id/${TPM_GROUP_ID}" \
    member_tpm_ids="${TPM_ID}"
ok "tpm_id added to identity/tpmgroup '${TPMGROUP_NAME}'"

# Bind role to tpmgroup — re-run safe: only create the role if it does not exist.
# If the role already exists, only update tpmgroup_ids (preserving any token_policies
# set by setup-gateway-credstore.sh).  Overwriting token_policies here would undo the
# least-privilege split done by Session 3-5e.
# Source: tpmidentity.sh line 57: vault write auth/tpm/role/$ROLENAME tpm_ids= tpmgroup_ids=$tpmgroupid
EXISTING_ROLE_POLICIES=$(vault read -format=json "auth/tpm/role/${ROLE_NAME}" 2>/dev/null | \
    python3 -c "import json,sys;print(','.join(json.load(sys.stdin)['data']['token_policies']))" 2>/dev/null || true)

if [[ -n "${EXISTING_ROLE_POLICIES}" ]]; then
    info "auth/tpm/role/${ROLE_NAME} already exists (token_policies=${EXISTING_ROLE_POLICIES}) — updating tpmgroup_ids only, not overwriting policies"
    vault write "auth/tpm/role/${ROLE_NAME}" \
        tpm_ids= \
        tpmgroup_ids="${TPM_GROUP_ID}"
    ok "auth/tpm/role/${ROLE_NAME} tpmgroup_ids updated to ${TPM_GROUP_ID} (policies unchanged: ${EXISTING_ROLE_POLICIES})"
else
    info "Creating auth/tpm/role/${ROLE_NAME} with tpmgroup_ids=${TPM_GROUP_ID} …"
    vault write "auth/tpm/role/${ROLE_NAME}" \
        tpm_ids= \
        tpmgroup_ids="${TPM_GROUP_ID}" \
        token_policies="edge-ai-demo-policy-edge" \
        token_ttl="1h" \
        token_max_ttl="4h"
    ok "auth/tpm/role/${ROLE_NAME} created and bound to tpmgroup_ids=${TPM_GROUP_ID}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Update edge-agent policy to allow auth/tpm/login
# ─────────────────────────────────────────────────────────────────────────────
section "Step 5: Verify edge-agent policy includes auth/tpm/login"

POLICY_NAME="edge-ai-demo-policy-edge"
if vault policy read "${POLICY_NAME}" 2>/dev/null | grep -q "auth/tpm/login"; then
    ok "Policy ${POLICY_NAME} already contains auth/tpm/login"
else
    info "Updating policy ${POLICY_NAME} to include auth/tpm/login …"
    EXISTING=$(vault policy read "${POLICY_NAME}" 2>/dev/null || true)
    NEW_STANZA='
# TPM auth — device hardware login (Phase 5)
path "auth/tpm/login" {
  capabilities = ["create", "update"]
}
path "auth/tpm/login/*" {
  capabilities = ["create", "update"]
}'
    printf '%s\n%s\n' "${EXISTING}" "${NEW_STANZA}" | vault policy write "${POLICY_NAME}" -
    ok "Policy ${POLICY_NAME} updated"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: Persist state to .vault-keys.json
# ─────────────────────────────────────────────────────────────────────────────
section "Step 6: Persist state"

python3 - "${KEYS_FILE}" "${TPM_GROUP_ID}" "${TPM_ID}" <<'PYEOF'
import json, sys
f, gid, tpm_id = sys.argv[1], sys.argv[2], sys.argv[3]
with open(f) as fh:
    d = json.load(fh)
d['tpm_group_id'] = gid
d['tpm_id']       = tpm_id
d.pop('enroll_token', None)   # remove any stale token from previous sessions
with open(f, 'w') as fh:
    json.dump(d, fh, indent=2)
print(f"  tpm_group_id={gid}")
print(f"  tpm_id={tpm_id}")
PYEOF
ok "State persisted to ${KEYS_FILE}"

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────
section "Mac-side TPM Auth Setup Complete"
echo ""
echo -e "${GREEN}Architecture summary:${NC}"
echo -e "  ${CYAN}Root token:${NC}       stayed on Mac — never sent to Jetson"
echo -e "  ${CYAN}EK pubkey:${NC}        read via tpm2_createek (no Vault auth), enrolled by Mac operator"
echo -e "  ${CYAN}vault tpm attest:${NC} runs on Jetson with NO token — hardware challenge/response only"
echo -e "  ${CYAN}tpm_id:${NC}           ${TPM_ID}"
echo -e "  ${CYAN}tpmgroup_id:${NC}      ${TPM_GROUP_ID}"
echo ""
echo -e "${CYAN}── Next step ────────────────────────────────────────────────────────────${NC}"
echo    "  ./scripts/bootstrap-jetson.sh ${JETSON_IP} --only-stage 5-1"
echo ""
echo -e "${CYAN}── Verification (Mac) ───────────────────────────────────────────────────${NC}"
echo    "  vault read auth/tpm/role/edge-camera-agent"
echo    "  vault read identity/tpmgroup/name/orin-nano-devices"
echo ""
