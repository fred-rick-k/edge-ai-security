#!/usr/bin/env bash
# scripts/11-tpm-enroll-and-agent.sh
# ──────────────────────────────────────────────────────────────────────────────
# Phase 5 Stage 5-1 / 5-1b: vault tpm attest + Vault Agent on Jetson.
#
# Supports two distinct vault-agent instances sharing the hardware TPM (/dev/tpmrm0):
#
#   1. Edge Instance (--instance edge / Stage 5-1):
#      - Role:        edge-camera-agent
#      - Policy:      edge-ai-demo-policy-edge
#      - Unit:        vault-agent.service
#      - Config:      /etc/vault-agent/vault-agent.hcl (mode 0600 root:root)
#      - TPM state:   /etc/vault-agent/tpm-edge (mode 0700 root:root)
#      - Token sink:  /run/openshell-edge/vault-token
#      - Sink perms:  mode 0640, root:edge-ingest (trusted-edge only, unreadable by jetson)
#      - Marker:      11_tpm_agent
#
#   2. Gateway Instance (--instance gateway / Stage 5-1b):
#      - Role:        openshell-gateway
#      - Policy:      edge-ai-demo-policy-gateway
#      - Unit:        vault-agent-gateway.service
#      - Config:      /etc/vault-agent/vault-agent-gateway.hcl (mode 0600 root:root)
#      - TPM state:   /etc/vault-agent/tpm-gateway (mode 0700 root:root)
#      - Token sink:  /run/openshell/vault-token
#      - Sink perms:  mode 0640, root:jetson (read by OpenShell gateway user unit)
#      - Marker:      11b_tpm_gateway_agent
#
# Zero plaintext credentials on the device at any point:
#   - Attestation is an unauthenticated challenge/response against the TPM EK.
#   - Authentication is performed autonomously by the hardware TPM chip.
#   - Tokens are written to tmpfs sinks with strict permissions and auto-renewed.
#
# Usage:
#   scripts/11-tpm-enroll-and-agent.sh --instance edge     # Stage 5-1
#   scripts/11-tpm-enroll-and-agent.sh --instance gateway  # Stage 5-1b
#   scripts/11-tpm-enroll-and-agent.sh --instance all      # Both + cross-verify
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${REPO_DIR}/.setup-state"
TPM_DEVICE="/dev/tpmrm0"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}  ▷ $*${NC}"; }
ok()      { echo -e "${GREEN}  ✓ $*${NC}"; }
warn()    { echo -e "${YELLOW}  ⚠ $*${NC}"; }
err()     { echo -e "${RED}  ✗ $*${NC}"; exit 1; }
section() { echo -e "\n${GREEN}══ $* ══${NC}"; }

# Sudo helpers with minimal env passthrough
sudoattest() {
    echo "${SUDO_PASS}" | sudo -S env \
        VAULT_ADDR="${VAULT_ADDR}" \
        VAULT_CACERT="${VAULT_CACERT}" \
        VAULT_TOKEN="" \
        "$@"
}
sudodevice() {
    echo "${SUDO_PASS}" | sudo -S env \
        VAULT_ADDR="${VAULT_ADDR}" \
        VAULT_CACERT="${VAULT_CACERT}" \
        VAULT_TOKEN="" \
        HOME="/root" \
        "$@"
}
sudocmd() { echo "${SUDO_PASS}" | sudo -S "$@"; }

# ── Parse arguments ───────────────────────────────────────────────────────────
INSTANCE="edge"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --instance)        INSTANCE="$2"; shift 2 ;;
        --instance=*)      INSTANCE="${1#--instance=}"; shift ;;
        --role)            ROLE_ARG="$2"; shift 2 ;;
        edge|5-1)          INSTANCE="edge"; shift ;;
        gateway|5-1b)      INSTANCE="gateway"; shift ;;
        all|both)          INSTANCE="all"; shift ;;
        *)                 echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ "${INSTANCE}" == "all" ]]; then
    info "Running dual-instance setup: edge (5-1) followed by gateway (5-1b)…"
    bash "$0" --instance edge
    bash "$0" --instance gateway
    exit 0
fi

# ── Instance Parameters ───────────────────────────────────────────────────────
case "${INSTANCE}" in
    edge)
        ROLE_NAME="edge-camera-agent"
        UNIT_NAME="vault-agent"
        UNIT_DESC="Vault Agent (TPM auto-auth — edge camera agent)"
        AGENT_CONFIG="/etc/vault-agent/vault-agent.hcl"
        TPM_STATE_DIR="/etc/vault-agent/tpm-edge"
        SINK_DIR="/run/openshell-edge"
        SINK_PATH="/run/openshell-edge/vault-token"
        SINK_MODE="0640"
        SINK_OWNER="root"
        SINK_GROUP="edge-ingest"
        SINK_DIR_MODE="0755"   # 3-5g: dir group was reset by an unidentified step; the secret is the 0640 file
        SINK_DIR_OWNER="root:root"
        MARKER="${STATE_DIR}/11_tpm_agent"
        EXPECTED_POLICY="edge-ai-demo-policy-edge"
        STAGE_LABEL="Stage 5-1 (tpm-agent)"
        ;;
    gateway)
        ROLE_NAME="openshell-gateway"
        UNIT_NAME="vault-agent-gateway"
        UNIT_DESC="Vault Agent (TPM auto-auth — openshell-gateway)"
        AGENT_CONFIG="/etc/vault-agent/vault-agent-gateway.hcl"
        TPM_STATE_DIR="/etc/vault-agent/tpm-gateway"
        SINK_DIR="/run/openshell"
        SINK_PATH="/run/openshell/vault-token"
        # 0640: root owns it; group jetson can read (openshell-gateway.service User=jetson).
        # Measured (3-5h run 2): without an explicit `owner`/`group` in the sink block,
        # vault-agent writes root:root (or root:jetson via RuntimeDirectory group) with mode
        # 0600 → jetson cannot read. 0640 + owner=0 group=<jetson-gid> in the HCL fixes this.
        SINK_MODE="0640"
        SINK_OWNER="root"
        SINK_GROUP="jetson"
        SINK_DIR_MODE="0755"
        SINK_DIR_OWNER="root:jetson"
        MARKER="${STATE_DIR}/11b_tpm_gateway_agent"
        EXPECTED_POLICY="edge-ai-demo-policy-gateway"
        STAGE_LABEL="Stage 5-1b (tpm-gateway-agent)"
        ;;
    *)
        err "Unknown instance type: ${INSTANCE}. Valid: edge, gateway, all"
        ;;
esac

# ── Idempotency Check ─────────────────────────────────────────────────────────
if [[ -f "${MARKER}" ]]; then
    echo -e "${GREEN}${STAGE_LABEL} already complete (marker exists). Skipping.${NC}"
    exit 0
fi
mkdir -p "${STATE_DIR}"

# ── Entry Checks ──────────────────────────────────────────────────────────────
section "${STAGE_LABEL} Entry Checks"

[[ -c "${TPM_DEVICE}" ]] || err "${TPM_DEVICE} not found."
ok "${TPM_DEVICE} present (in-kernel resource manager supports concurrent clients)"

: "${VAULT_ADDR:?VAULT_ADDR must be set (injected by bootstrap)}"
: "${VAULT_CACERT:?VAULT_CACERT must be set (injected by bootstrap — path to tls/vault.crt)}"
[[ -f "${VAULT_CACERT}" ]] || err "VAULT_CACERT file not found: ${VAULT_CACERT}. Check tls/vault.crt was synced."

curl -s --cacert "${VAULT_CACERT}" --max-time 5 "${VAULT_ADDR}/v1/sys/health" | \
    python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if not d.get('sealed') else 1)" \
    2>/dev/null || err "Vault at ${VAULT_ADDR} is not reachable or is sealed."
ok "Vault reachable and unsealed at ${VAULT_ADDR}"

export VAULT_ADDR VAULT_CACERT

# ── Step 1: System User & Group Setup ─────────────────────────────────────────
section "Step 1: System User & Group Configuration"

if ! getent group edge-ingest >/dev/null 2>&1; then
    info "Creating system group edge-ingest…"
    sudocmd groupadd -r edge-ingest
    ok "Group edge-ingest created"
else
    ok "Group edge-ingest exists"
fi

if ! getent passwd edge-ingest >/dev/null 2>&1; then
    info "Creating system user edge-ingest (no login shell, no docker/sudo)…"
    sudocmd useradd -r -g edge-ingest -s /usr/sbin/nologin -d /nonexistent -c "Edge Ingest Service" edge-ingest
    ok "User edge-ingest created"
else
    ok "User edge-ingest exists"
fi

# Ensure /etc/vault-agent parent directory exists with secure perms
sudocmd mkdir -p /etc/vault-agent
sudocmd chmod 700 /etc/vault-agent

# Ensure sink directory exists with proper ownership and permissions
sudocmd mkdir -p "${SINK_DIR}"
sudocmd chown "${SINK_DIR_OWNER}" "${SINK_DIR}"
sudocmd chmod "${SINK_DIR_MODE}" "${SINK_DIR}"
ok "Sink directory configured: ${SINK_DIR} (${SINK_DIR_OWNER} ${SINK_DIR_MODE})"

# If running edge setup and gateway agent is not active yet, clean stale legacy token at /run/openshell/vault-token
if [[ "${INSTANCE}" == "edge" ]] && ! systemctl is-active --quiet vault-agent-gateway 2>/dev/null; then
    if sudocmd test -f "/run/openshell/vault-token" 2>/dev/null; then
        info "Retiring stale legacy /run/openshell/vault-token (will be recreated by vault-agent-gateway in Stage 5-1b)…"
        sudocmd rm -f "/run/openshell/vault-token"
    fi
fi

# ── Step 2: vault tpm attest ──────────────────────────────────────────────────
section "Step 2: vault tpm attest (role: ${ROLE_NAME})"

sudocmd mkdir -p "${TPM_STATE_DIR}"
sudocmd chmod 700 "${TPM_STATE_DIR}"

# Clean stale state if needed
if sudocmd test -f "${TPM_STATE_DIR}/client.crt" 2>/dev/null; then
    info "Cleaning stale TPM client cert from ${TPM_STATE_DIR}…"
    sudodevice vault tpm cleanup \
        -tpm-device-path="${TPM_DEVICE}" \
        -tpm-state-dir="${TPM_STATE_DIR}" 2>/dev/null || true
fi

info "Attesting hardware TPM for role ${ROLE_NAME} (unauthenticated challenge/response)…"
# Vault TPM auth (documented, developer.hashicorp.com/vault/docs/auth/tpm): "new requests from the same EK are
# rate-limited to one every 10 seconds". Stages 5-1 and 5-1b attest the SAME TPM, so in the default order 5-1b
# can start inside that window and Vault answers "rate limit exceeded for this EK" (seen 2026-11-03, Session
# 7-2d). Retry ONLY on that exact message; any other failure aborts at once.
ATTEST_OK=false
for ATTEMPT in 1 2 3 4; do
    if ATTEST_OUT="$(sudoattest vault tpm attest \
            -role-name="${ROLE_NAME}" \
            -tpm-device-path="${TPM_DEVICE}" \
            -tpm-state-dir="${TPM_STATE_DIR}" 2>&1)"; then
        echo "${ATTEST_OUT}"
        ATTEST_OK=true
        break
    fi
    echo "${ATTEST_OUT}"
    if grep -q "rate limit exceeded for this EK" <<<"${ATTEST_OUT}" && [[ "${ATTEMPT}" -lt 4 ]]; then
        warn "Vault allows one attestation per EK every 10 s — waiting 12 s, then retrying (attempt ${ATTEMPT}/4)"
        sleep 12
        continue
    fi
    break
done
[[ "${ATTEST_OK}" == "true" ]] || err "vault tpm attest failed for role ${ROLE_NAME} (output above)"

if ! sudocmd test -f "${TPM_STATE_DIR}/client.crt" 2>/dev/null; then
    err "vault tpm attest did not produce ${TPM_STATE_DIR}/client.crt"
fi
ok "Client certificate written to ${TPM_STATE_DIR}/client.crt"

# ── Step 3: vault login -method=tpm Smoke Test ────────────────────────────────
section "Step 3: vault login -method=tpm smoke test"

info "Testing autonomous TPM login for role ${ROLE_NAME}…"
LOGIN_OUT=$(sudodevice vault login \
    -method=tpm \
    -tpm-device-path="${TPM_DEVICE}" \
    -tpm-state-dir="${TPM_STATE_DIR}" \
    -token-only \
    -no-store \
    role_name="${ROLE_NAME}" 2>&1) || LOGIN_OUT="FAILED"

if [[ "${LOGIN_OUT}" == hvs.* ]] || [[ "${LOGIN_OUT}" == hvb.* ]]; then
    ok "vault login -method=tpm succeeded (token prefix: ${LOGIN_OUT:0:12}…)"
else
    warn "vault login output: ${LOGIN_OUT}"
    warn "Vault Agent will retry autonomously — continuing."
fi

# ── Step 4: Write Agent HCL Configuration ─────────────────────────────────────
section "Step 4: Write ${AGENT_CONFIG}"

# vault agent file sink: without explicit owner/group in the sink block, vault-agent writes the
# token with owner=0 group=0 (measured, 3-5g for edge) or group=<RuntimeDirectory gid> but still
# mode 0600 (measured, 3-5h run 2 for gateway) — in either case the intended reader cannot read.
# Fix: always set owner=0 and group=<intended-gid> in the sink block; mode set above.
# Resolved here, after group creation, because getent needs the group to exist.
SINK_OWNERSHIP=""
case "${INSTANCE}" in
    edge)
        EDGE_GID="$(getent group edge-ingest | cut -d: -f3)"
        [[ -n "${EDGE_GID}" ]] || err "cannot resolve gid of group edge-ingest"
        SINK_OWNERSHIP="      owner = 0
      group = ${EDGE_GID}"
        ;;
    gateway)
        JETSON_GID="$(getent group jetson | cut -d: -f3)"
        [[ -n "${JETSON_GID}" ]] || err "cannot resolve gid of group jetson"
        SINK_OWNERSHIP="      owner = 0
      group = ${JETSON_GID}"
        ;;
esac
AGENT_HCL_TMP=$(mktemp /tmp/vault-agent-hcl.XXXXXX)
cat <<AGENT_HCL > "${AGENT_HCL_TMP}"
# ${AGENT_CONFIG}
# ${UNIT_DESC}
# Hardware-rooted auto-auth via OP-TEE TPM 2.0 (${TPM_DEVICE}).

vault {
  address = "${VAULT_ADDR}"
  ca_cert = "${VAULT_CACERT}"
}

tpm_cert "machine" {
  mount_path = "auth/tpm"
  role_name  = "${ROLE_NAME}"

  renew {
    percent_renew_before_expiry = 20
  }

  tpm {
    device_path = "${TPM_DEVICE}"
  }

  destination {
    path  = "${TPM_STATE_DIR}"
    umask = "077"
  }
}

auto_auth {
  method "tpm" {
    mount_path  = "auth/tpm"
    exit_on_err = false
    config = {
      tpm_cert      = "machine"
      reload        = true
      reload_period = "30s"
    }
  }

  sink "file" {
    config = {
      path = "${SINK_PATH}"
      mode = ${SINK_MODE}
${SINK_OWNERSHIP:+${SINK_OWNERSHIP}
}    }
  }
}
AGENT_HCL

sudocmd cp "${AGENT_HCL_TMP}" "${AGENT_CONFIG}"
rm -f "${AGENT_HCL_TMP}"
sudocmd chown root:root "${AGENT_CONFIG}"
sudocmd chmod 600 "${AGENT_CONFIG}"
ok "${AGENT_CONFIG} written (mode 0600 root:root)"

# ── Step 5: Write and Start systemd Unit ───────────────────────────────────────
section "Step 5: Configure ${UNIT_NAME}.service"

SERVICE_UNIT_TMP=$(mktemp /tmp/vault-agent-service.XXXXXX)
cat > "${SERVICE_UNIT_TMP}" <<SERVICE_UNIT
[Unit]
Description=${UNIT_DESC}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=${SINK_GROUP}
Environment=VAULT_ADDR=${VAULT_ADDR}
Environment=VAULT_CACERT=${VAULT_CACERT}
ExecStart=/usr/local/bin/vault agent -config=${AGENT_CONFIG}
ExecStartPost=/bin/bash -c "for i in {1..20}; do if [ -s ${SINK_PATH} ]; then chown ${SINK_OWNER}:${SINK_GROUP} ${SINK_PATH} && chmod ${SINK_MODE} ${SINK_PATH}; break; fi; sleep 0.5; done"
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
KillSignal=SIGTERM
TimeoutStopSec=30
Restart=on-failure
RestartSec=10
RuntimeDirectory=$(basename "${SINK_DIR}")
RuntimeDirectoryMode=${SINK_DIR_MODE}
RuntimeDirectoryPreserve=yes
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${UNIT_NAME}

[Install]
WantedBy=multi-user.target
SERVICE_UNIT

sudocmd cp "${SERVICE_UNIT_TMP}" "/etc/systemd/system/${UNIT_NAME}.service"
rm -f "${SERVICE_UNIT_TMP}"
sudocmd systemctl daemon-reload

if systemctl is-active --quiet "${UNIT_NAME}" 2>/dev/null; then
    info "Restarting ${UNIT_NAME}.service…"
    sudocmd systemctl restart "${UNIT_NAME}"
else
    info "Enabling + starting ${UNIT_NAME}.service…"
    sudocmd systemctl enable "${UNIT_NAME}"
    sudocmd systemctl start "${UNIT_NAME}"
fi
ok "${UNIT_NAME}.service started"

# ── Step 6: Wait for Token Sink & Apply Enforced Permissions ─────────────────
section "Step 6: Wait for token sink (${SINK_PATH})"

info "Waiting for ${SINK_PATH} to appear and contain valid token…"
for i in $(seq 1 15); do
    if sudocmd test -s "${SINK_PATH}" 2>/dev/null; then
        ok "Token sink appeared after ~${i} s"
        break
    fi
    if [[ "${i}" -eq 15 ]]; then
        warn "Token sink not present after 15 s — ${UNIT_NAME} logs:"
        sudocmd journalctl -u "${UNIT_NAME}" --no-pager -n 50 || true
        err "${UNIT_NAME} did not produce ${SINK_PATH}."
    fi
    sleep 1
done

# Apply explicit ownership & permissions to be 100% certain
sudocmd chown "${SINK_OWNER}:${SINK_GROUP}" "${SINK_PATH}"
sudocmd chmod "${SINK_MODE}" "${SINK_PATH}"

PERMS=$(sudocmd stat -c '%a %U:%G' "${SINK_PATH}")
ok "Token file permissions: ${SINK_PATH} -> ${PERMS}"

# ── Step 7: Validate Token & Identity ─────────────────────────────────────────
section "Step 7: Token Validation (lookup-self)"

SINK_TOKEN=$(sudocmd cat "${SINK_PATH}")
LOOKUP_RESP=$(curl -s --cacert "${VAULT_CACERT}" "${VAULT_ADDR}/v1/auth/token/lookup-self" \
    -H "X-Vault-Token: ${SINK_TOKEN}")

DISPLAY_NAME=$(echo "${LOOKUP_RESP}" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('display_name','INVALID'))" 2>/dev/null || echo "INVALID")
POLICIES=$(echo "${LOOKUP_RESP}" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(','.join(d.get('data',{}).get('policies',[])))" 2>/dev/null || echo "")

if [[ "${DISPLAY_NAME}" == "INVALID" ]] || [[ -z "${DISPLAY_NAME}" ]]; then
    sudocmd journalctl -u "${UNIT_NAME}" --no-pager -n 40 || true
    err "Token in ${SINK_PATH} is not valid."
fi

ok "Token valid — display_name: ${DISPLAY_NAME}"
ok "Token policies: [${POLICIES}]"

if [[ ",${POLICIES}," != *",${EXPECTED_POLICY},"* ]]; then
    err "Token missing expected policy '${EXPECTED_POLICY}'. Actual policies: [${POLICIES}]"
fi
ok "Expected policy '${EXPECTED_POLICY}' confirmed on token"

# ── Step 8: Comprehensive Dual-Token Cross-Verification ───────────────────────
section "Step 8: System-Wide Token Security & Cross-Deny Verification"

EDGE_SINK="/run/openshell-edge/vault-token"
GW_SINK="/run/openshell/vault-token"

# Check if both instances are active and present on system
BOTH_ACTIVE=false
if systemctl is-active --quiet vault-agent 2>/dev/null && \
   systemctl is-active --quiet vault-agent-gateway 2>/dev/null && \
   sudocmd test -s "${EDGE_SINK}" 2>/dev/null && \
   sudocmd test -s "${GW_SINK}" 2>/dev/null; then
    BOTH_ACTIVE=true
    # Session 7-2e (fresh-start run 2026-11-04, stage 5-1 failed here): "unit active" and "sink non-empty" do not
    # prove the OTHER instance's token belongs to the CURRENT Vault. After the Mac's Vault was wiped, the still
    # running vault-agent-gateway kept a token from the old Vault and the gateway write returned 403. Look up each
    # token (lookup-self) first; a token the current Vault does not know means this step cannot run - say so.
    for _sink in "${EDGE_SINK}" "${GW_SINK}"; do
        _t="$(sudocmd cat "${_sink}")"
        _code="$(curl -s --cacert "${VAULT_CACERT}" -o /dev/null -w '%{http_code}' \
            -H "X-Vault-Token: ${_t}" "${VAULT_ADDR}/v1/auth/token/lookup-self" || true)"
        unset _t
        if [[ "${_code}" != "200" ]]; then
            BOTH_ACTIVE=false
            warn "Step 8 NOT RUN: token in ${_sink} is not valid against the current Vault (lookup-self HTTP ${_code})."
            warn "  Likely a still-running agent from a previous Vault. Re-run its stage (5-1 edge / 5-1b gateway) to re-attest."
        fi
    done
fi
if [[ "${BOTH_ACTIVE}" == "true" ]]; then
    info "Both token instances active on host. Executing comprehensive cross-verification…"
    
    # Enforce exact permissions and ownership.
    # Gateway token: 0640 root:jetson — vault-agent-gateway runs as root, HCL sink has
    # owner=0 group=<jetson-gid>. openshell-gateway user is jetson (group jetson) → can read.
    # (Measured 3-5h run 1/2: without owner/group in the HCL, the file was root:root 0600 or
    # root:jetson 0600 — both unreadable by jetson. Fix: 0640 root:jetson.)
    sudocmd chown root:edge-ingest "${EDGE_SINK}"
    sudocmd chmod 0640 "${EDGE_SINK}"
    sudocmd chown root:jetson "${GW_SINK}"
    sudocmd chmod 0640 "${GW_SINK}"

    EDGE_PERMS=$(sudocmd stat -c '%a %U:%G' "${EDGE_SINK}")
    GW_PERMS=$(sudocmd stat -c '%a %U:%G' "${GW_SINK}")

    info "Edge token:   ${EDGE_SINK} -> ${EDGE_PERMS}"
    info "Gateway token: ${GW_SINK} -> ${GW_PERMS}"

    # 1. Permission checks
    [[ "${EDGE_PERMS}" == "640 root:edge-ingest" ]] || err "Edge token perms mismatch: expected '640 root:edge-ingest', got '${EDGE_PERMS}'"
    ok "Edge token permissions verified: 640 root:edge-ingest"

    [[ "${GW_PERMS}" == "640 root:jetson" ]] || err "Gateway token perms mismatch: expected '640 root:jetson', got '${GW_PERMS}'"
    ok "Gateway token permissions verified: 640 root:jetson"
    
    # 2. Assert NO world-readable tokens exist
    for f in "${EDGE_SINK}" "${GW_SINK}"; do
        other_perm=$(sudocmd stat -c '%a' "$f" | cut -c3)
        if [[ "${other_perm}" != "0" ]]; then
            err "SECURITY VIOLATION: $f is world-readable (mode ${other_perm})!"
        fi
    done
    ok "No world-readable tokens found on system (other-bits = 0)"
    
    # 3. Test unprivileged access by jetson user
    if sudo -u jetson cat "${EDGE_SINK}" >/dev/null 2>&1; then
        err "SECURITY VIOLATION: user 'jetson' can read ${EDGE_SINK} without sudo!"
    else
        ok "User 'jetson' denied access to ${EDGE_SINK} (unprivileged read blocked ✓)"
    fi
    
    EDGE_TOK=$(sudocmd cat "${EDGE_SINK}")
    GW_TOK=$(sudocmd cat "${GW_SINK}")
    
    # 4. Capability verification — Edge Token
    info "Testing Edge Token capabilities & cross-denials…"
    
    # Edge ALLOWED: Transit datakey
    CT_RESP=$(curl -s --cacert "${VAULT_CACERT}" -X POST -H "X-Vault-Token: ${EDGE_TOK}" \
        -d '{}' "${VAULT_ADDR}/v1/edge-ai-demo-encryption-transit/datakey/plaintext/edge-telemetry")
    if echo "${CT_RESP}" | grep -q "vault:v1:"; then
        ok "Edge token -> Transit datakey ALLOWED (HTTP 200, vault:v1:... ciphertext)"
    else
        err "Edge token -> Transit datakey FAILED: ${CT_RESP}"
    fi
    
    # Edge ALLOWED: Dynamic DB credentials
    DB_RESP=$(curl -s --cacert "${VAULT_CACERT}" -H "X-Vault-Token: ${EDGE_TOK}" \
        "${VAULT_ADDR}/v1/edge-ai-demo-database/creds/edge-camera-agent")
    if echo "${DB_RESP}" | grep -q "username"; then
        ok "Edge token -> Dynamic DB creds ALLOWED (HTTP 200, credentials issued)"
    else
        err "Edge token -> Dynamic DB creds FAILED: ${DB_RESP}"
    fi
    
    # Edge DENIED: Gateway mount write
    EDGE_DENY_CODE=$(curl -s --cacert "${VAULT_CACERT}" -o /dev/null -w "%{http_code}" \
        -X POST -H "X-Vault-Token: ${EDGE_TOK}" -H "Content-Type: application/json" \
        -d '{"data":{"cross":"test"}}' \
        "${VAULT_ADDR}/v1/edge-ai-demo-gateway/data/openshell/provider-credentials/cross-deny-test")
    if [[ "${EDGE_DENY_CODE}" == "403" ]]; then
        ok "Edge token -> Gateway credstore write DENIED (HTTP 403 Permission Denied ✓)"
    else
        err "Cross-deny violation: Edge token wrote to gateway mount (HTTP ${EDGE_DENY_CODE})"
    fi
    
    # 5. Capability verification — Gateway Token
    info "Testing Gateway Token capabilities & cross-denials…"
    
    # Gateway ALLOWED: Gateway mount write + read + delete
    GW_WRITE_CODE=$(curl -s --cacert "${VAULT_CACERT}" -o /dev/null -w "%{http_code}" \
        -X POST -H "X-Vault-Token: ${GW_TOK}" -H "Content-Type: application/json" \
        -d '{"data":{"value":"test-gw-val"}}' \
        "${VAULT_ADDR}/v1/edge-ai-demo-gateway/data/openshell/provider-credentials/dual-token-test")
    if [[ "${GW_WRITE_CODE}" == "200" ]]; then
        ok "Gateway token -> Gateway credstore write ALLOWED (HTTP 200 ✓)"
    else
        err "Gateway token -> Gateway credstore write FAILED (HTTP ${GW_WRITE_CODE})"
    fi
    
    # Gateway cleanup test key
    curl -s --cacert "${VAULT_CACERT}" -X DELETE -H "X-Vault-Token: ${GW_TOK}" \
        "${VAULT_ADDR}/v1/edge-ai-demo-gateway/metadata/openshell/provider-credentials/dual-token-test" >/dev/null 2>&1 || true
    
    # Gateway DENIED: Camera creds KV read
    GW_KV_CODE=$(curl -s --cacert "${VAULT_CACERT}" -o /dev/null -w "%{http_code}" \
        -H "X-Vault-Token: ${GW_TOK}" \
        "${VAULT_ADDR}/v1/edge-ai-demo-kv/data/edge-device/camera-creds")
    if [[ "${GW_KV_CODE}" == "403" ]]; then
        ok "Gateway token -> Camera KV creds read DENIED (HTTP 403 Permission Denied ✓)"
    else
        err "Cross-deny violation: Gateway token read camera creds (HTTP ${GW_KV_CODE})"
    fi
    
    # Gateway DENIED: Transit datakey request
    GW_TRANSIT_CODE=$(curl -s --cacert "${VAULT_CACERT}" -o /dev/null -w "%{http_code}" \
        -X POST -H "X-Vault-Token: ${GW_TOK}" -d '{}' \
        "${VAULT_ADDR}/v1/edge-ai-demo-encryption-transit/datakey/plaintext/edge-telemetry")
    if [[ "${GW_TRANSIT_CODE}" == "403" ]]; then
        ok "Gateway token -> Transit datakey request DENIED (HTTP 403 Permission Denied ✓)"
    else
        err "Cross-deny violation: Gateway token requested datakey (HTTP ${GW_TRANSIT_CODE})"
    fi
    
    # Gateway DENIED: Dynamic DB creds
    GW_DB_CODE=$(curl -s --cacert "${VAULT_CACERT}" -o /dev/null -w "%{http_code}" \
        -H "X-Vault-Token: ${GW_TOK}" \
        "${VAULT_ADDR}/v1/edge-ai-demo-database/creds/edge-camera-agent")
    if [[ "${GW_DB_CODE}" == "403" ]]; then
        ok "Gateway token -> Dynamic DB creds request DENIED (HTTP 403 Permission Denied ✓)"
    else
        err "Cross-deny violation: Gateway token requested DB creds (HTTP ${GW_DB_CODE})"
    fi
else
    info "Step 8 NOT RUN (cross-verification needs both agents active with tokens valid against the current Vault; see above). It runs when 5-1b completes."
fi

# ── Step 9: Mark Complete ─────────────────────────────────────────────────────
touch "${MARKER}"

section "${STAGE_LABEL} Complete"
echo ""
echo -e "${GREEN}Dual Vault-Agent Instance Summary:${NC}"
echo -e "  ${CYAN}Instance:${NC}         ${INSTANCE}"
echo -e "  ${CYAN}Role name:${NC}        ${ROLE_NAME}"
echo -e "  ${CYAN}Policy:${NC}           ${EXPECTED_POLICY}"
echo -e "  ${CYAN}Systemd unit:${NC}     ${UNIT_NAME}.service"
echo -e "  ${CYAN}Token sink:${NC}       ${SINK_PATH} (${PERMS})"
echo -e "  ${CYAN}display_name:${NC}     ${DISPLAY_NAME}"
echo -e "  ${CYAN}TPM state dir:${NC}    ${TPM_STATE_DIR}"
echo ""
