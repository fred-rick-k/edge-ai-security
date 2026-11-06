#!/usr/bin/env bash
# scripts/15-install-gateway-vault-driver.sh
# Phase 3 Stage 3-5h (gateway-vault-driver) — marker 13a_gateway_vault_driver.
#
# Makes the gateway Vault credential driver PERMANENT and creates two providers:
#   • edge-ingest  — X-Edge-Key header injection for trusted-edge.service (:8095)
#   • cosmos-vlm   — inference provider profile for llama-server (:8090)
#
# Docs consulted (AGENTS.md §0.1 rule 6):
#   https://docs.nvidia.com/openshell/latest/how-it-works/gateways/configuration.md
#   https://docs.nvidia.com/openshell/latest/how-it-works/providers/profiles.md
#   https://docs.nvidia.com/openshell/latest/how-it-works/inference.md
#
# Design references:
#   • CHANGELOG 3-5d run 2: working toml snippet (C1), F1/F4/F5 path behaviour.
#   • AGENTS.md §3: gateway token /run/openshell/vault-token (0640 root:jetson).
#   • AGENTS.md §3: trusted-edge port 8095, ingest key in /etc/trusted-edge/ingest-key.handoff
#     (root 0600); VLM port 8090.
#   • AGENTS.md §3: policy needs DNS names (not IPs).
#   • 14d probe: apply_driver, wait_gateway, put_toml_from, Vault curl helpers.
#
# What this script does (every check is real; nothing is simulated):
#   0. Entry checks: markers 11b_tpm_gateway_agent + 13_trusted_edge; Vault reachable;
#      handoff file present; no existing providers (driver switch requires none).
#   1. Back up gateway.toml; write the Vault driver config permanently; preflight; restart;
#      wait Connected.  Fail closed: abort and restore if any step fails.
#   2. Probe provider round-trip (dummy secret): prove one Vault entry is created and deleted.
#   3. Create profile + provider edge-ingest: read the key from the handoff file (never printed),
#      import the profile, create the provider.  Verify the sandbox delivers HTTP 200 on
#      GET /frame.jpg via the X-Edge-Key header.
#   4. Delete the handoff file ONLY after the sandbox delivered HTTP 200.
#   5. Create profile + provider cosmos-vlm: no credentials; verify GET /health is 200 from
#      inside a sandbox carrying the provider.
#   6. Measure where `provider update` stores the rotated value in Vault (open item from 3-5d F4):
#      compare key list and version before and after; record findings.  This is informational;
#      the stage does not fail if S2 is at a new path as long as the update API returns 0.
#   7. Restore: sandbox + probe provider deleted in step 2; cosmos probe sandbox deleted.
#      edge-ingest provider and cosmos-vlm provider remain (permanent install).
#
# Usage: ./scripts/bootstrap-jetson.sh <jetson-ip> --only-stage 3-5h
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${REPO_ROOT}/.setup-state"
MARKER="${STATE_DIR}/13a_gateway_vault_driver"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1090,SC1091
  source "${REPO_ROOT}/.env"
  set +a
fi

# ── constants ────────────────────────────────────────────────────────────────
TOKEN_FILE="/run/openshell/vault-token"
MOUNT="edge-ai-demo-gateway"
KV_PREFIX="openshell/provider-credentials"
MAC_IP="${MAC_IP:-127.0.0.1}"
VAULT_PORT="${VAULT_PORT:-8200}"
V_IP="${VAULT_ADDR:-https://${MAC_IP}:${VAULT_PORT}}"
TE_PORT="${TRUSTED_EDGE_PORT:-${TE_PORT:-8095}}"
VLM_PORT="${VLM_PORT:-8090}"
JETSON_HOSTNAME="${JETSON_HOSTNAME:-jetson.localdomain}"
CFG_DIR="${HOME}/.config/openshell"
GW_TOML="${CFG_DIR}/gateway.toml"
GW_BACKUP="${GW_TOML}.pre-3-5h"
CA_COPY="${CFG_DIR}/vault-gateway-ca-self.pem"
CA_SRC="${REPO_ROOT}/tls/vault.crt"
HANDOFF_KEY="/etc/trusted-edge/ingest-key.handoff"
AGENT_IMAGE="edge-agent-sandbox:dev"
# Sandbox names: 19-char max (verified from 3-5h run 5 error).
# Use last 4 digits of PID for uniqueness.
_SFX="${$: -4}"
PROBE_SB="probe-3h-${_SFX}"
INGEST_SB="ing-3h-${_SFX}"
VLM_SB="vlm-3h-${_SFX}"
PROBE_PROFILE="probe-3-5h"
PROBE_PROVIDER="probe-3-5h"
INGEST_PROFILE="edge-ingest"
INGEST_PROVIDER="edge-ingest"
VLM_PROFILE="cosmos-vlm"
VLM_PROVIDER="cosmos-vlm"

# tmpfiles
PROBE_PROFILE_YAML="/tmp/profile-${PROBE_PROFILE}.yaml"
INGEST_PROFILE_YAML="/tmp/profile-${INGEST_PROFILE}.yaml"
VLM_PROFILE_YAML="/tmp/profile-${VLM_PROFILE}.yaml"
PROBE_POLICY="/tmp/policy-${PROBE_PROFILE}.yaml"
INGEST_POLICY="/tmp/policy-${INGEST_PROFILE}.yaml"
VLM_POLICY="/tmp/policy-${VLM_PROFILE}.yaml"

RUN_ID="$$-$(date +%s)"
S1="probe-secret-1-${RUN_ID}"
S2="probe-secret-2-${RUN_ID}"

export XDG_RUNTIME_DIR="/run/user/$(id -u)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}  ▷ $*${NC}"; }
ok()      { echo -e "${GREEN}  ✓ $*${NC}"; }
warn()    { echo -e "${YELLOW}  ⚠ $*${NC}"; }
err()     { echo -e "${RED}  ✗ $*${NC}"; exit 1; }
section() { echo -e "\n${GREEN}══ $* ══${NC}"; }

sudocmd() { echo "${SUDO_PASS}" | sudo -S "$@"; }

# ── gateway.toml helpers (reuse pattern from 14d) ───────────────────────────
put_toml_from() {  # $1=source file
    local tmp="${GW_TOML}.tmp.$$"
    cp "$1" "${tmp}" && chmod 644 "${tmp}" && mv -f "${tmp}" "${GW_TOML}"
}

apply_driver() {
    local tmp="${GW_TOML}.new.$$"
    cp "${GW_BACKUP}" "${tmp}" || return 1
    python3 - "${tmp}" "${V_IP}" "${CA_COPY}" "${TOKEN_FILE}" "${MOUNT}" <<'PY'
import sys
path, addr, ca, tok, mount = sys.argv[1:6]
out = []
for ln in open(path).read().splitlines():
    out.append(ln)
    if ln.strip() == "[openshell.gateway]":
        out.append('credential_drivers = ["vault"]')
txt = "\n".join(out).rstrip() + "\n\n[openshell.credential_drivers.vault]\n"
txt += 'address = "%s"\n' % addr
txt += 'ca_bundle = "%s"\n' % ca
txt += 'mount = "%s"\nkv_version = "2"\nauth_method = "token_file"\ntoken_path = "%s"\n' % (mount, tok)
open(path, "w").write(txt)
PY
    [[ $? -eq 0 ]] || { rm -f "${tmp}"; return 1; }
    put_toml_from "${tmp}" && rm -f "${tmp}" || { rm -f "${tmp}"; return 1; }
    grep -q '^credential_drivers = \["vault"\]' "${GW_TOML}"
}

wait_gateway() {
    for _ in $(seq 1 30); do
        openshell status 2>&1 | grep -q "Status: Connected" && return 0
        sleep 2
    done
    return 1
}

# ── Vault helpers ─────────────────────────────────────────────────────────────
# All calls use the gateway token (not the edge token).
# Read via sudo: the file may be 600 root:jetson (jetson cannot read without sudo) or
# 640 root:jetson (jetson CAN read directly). Use sudo to be safe in both cases.
tok() { sudocmd cat "${TOKEN_FILE}" 2>/dev/null || true; }
vcurl() {  # $1=token $2=METHOD $3=api-path
    curl -sS --max-time 10 --cacert "${CA_COPY}" -X "$2" -H "X-Vault-Token: $1" \
        -w '\n%{http_code}' "${V_IP}/v1/$3" 2>&1
}
vcode() { vcurl "$@" | tail -1; }
vbody() { vcurl "$@" | sed '$d'; }
jget() { python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    for k in sys.argv[1].split('.'):
        d=d[int(k)] if k.isdigit() else d[k]
    print(','.join(map(str,d)) if isinstance(d,list) else d)
except Exception:
    print('')" "$1"; }

list_kv_keys() {  # returns comma-separated keys under KV_PREFIX, "" if none
    vbody "$(tok)" LIST "${MOUNT}/metadata/${KV_PREFIX}" | jget "data.keys"
}

# ── cleanup ───────────────────────────────────────────────────────────────────
cleanup() {
    openshell sandbox delete "${PROBE_SB}"  >/dev/null 2>&1 || true
    openshell sandbox delete "${INGEST_SB}" >/dev/null 2>&1 || true
    openshell sandbox delete "${VLM_SB}"    >/dev/null 2>&1 || true
    openshell provider delete "${PROBE_PROVIDER}" >/dev/null 2>&1 || true
    openshell profile  delete "${PROBE_PROFILE}"  >/dev/null 2>&1 || true
    rm -f "${PROBE_PROFILE_YAML}" "${PROBE_POLICY}" "${INGEST_POLICY}" "${VLM_POLICY}"
}
trap cleanup EXIT

# ── idempotency guard ─────────────────────────────────────────────────────────
if [[ -f "${MARKER}" ]]; then
    echo -e "${GREEN}Stage 3-5h already complete (marker exists). Skipping.${NC}"
    exit 0
fi
mkdir -p "${STATE_DIR}"

# ── 0. Entry checks ───────────────────────────────────────────────────────────
section "0. Entry checks"
[[ -f "${STATE_DIR}/11b_tpm_gateway_agent" ]] || err "Stage 5-1b (11b_tpm_gateway_agent) not complete."
[[ -f "${STATE_DIR}/13_trusted_edge" ]]        || err "Stage 3-5g (13_trusted_edge) not complete."
ok "markers 11b_tpm_gateway_agent and 13_trusted_edge present"

: "${VAULT_ADDR:?VAULT_ADDR must be set (bootstrap)}"
: "${VAULT_CACERT:?VAULT_CACERT must be set (bootstrap)}"
[[ -f "${VAULT_CACERT}" ]] || err "VAULT_CACERT file not found: ${VAULT_CACERT}"
[[ -s "${CA_SRC}" ]] || err "tls/vault.crt not found (should have been copied by bootstrap)"
ok "Vault CA cert present at ${CA_SRC}"

# Ensure the CA copy in the openshell config dir is fresh
install -m 644 "${CA_SRC}" "${CA_COPY}"
ok "CA cert copied to ${CA_COPY}"

# Check the gateway token file (vault-agent-gateway writes it).
# Measured (3-5h run 1): vault-agent-gateway.service runs as root; the gateway sink has
# `group = <jetson-gid>` but no `owner` override, so vault-agent writes the file as
# `root:jetson` (not `jetson:jetson`). The openshell-gateway.service user IS `jetson`, which
# is in group `jetson`, so it CAN read the file. Accept both variants.
[[ -s "${TOKEN_FILE}" ]] || err "gateway token file not found or empty: ${TOKEN_FILE}"
GW_TOKEN_OWNER="$(stat -c '%a %U:%G' "${TOKEN_FILE}" 2>/dev/null || echo '?')"
case "${GW_TOKEN_OWNER}" in
    "640 root:jetson"|"600 root:jetson"|"640 jetson:jetson"|"600 jetson:jetson")
        ok "gateway token file present: ${TOKEN_FILE} (${GW_TOKEN_OWNER}) — jetson can read" ;;
    *)
        err "gateway token file has unexpected permissions: ${GW_TOKEN_OWNER}. Expected '640 root:jetson' (after stage 5-1b re-run) or '600 root:jetson'. Run: ./scripts/bootstrap-jetson.sh <jetson-ip> --reset-stage 5-1b" ;;
esac

# Vault reachable with the gateway token
TOK_VAL="$(tok)"
[[ -n "${TOK_VAL}" ]] || err "gateway token file is empty"
POL="$(vbody "${TOK_VAL}" GET auth/token/lookup-self | jget "data.policies")"
info "gateway token policies: ${POL}"
[[ "${POL}" == *"edge-ai-demo-policy-gateway"* ]] \
    || err "gateway token does not carry edge-ai-demo-policy-gateway. Check: systemctl is-active vault-agent-gateway; journalctl -u vault-agent-gateway -n 20"
ok "gateway token carries edge-ai-demo-policy-gateway"

# trusted-edge must be listening
systemctl is-active --quiet trusted-edge \
    || err "trusted-edge.service is not active — required for the ingest provider verification step."
ok "trusted-edge.service active"

# Probe/ingest/VLM sandboxes below are created --from the agent image, which stage 3-5i normally builds
# later. Build it here if it is missing (same Dockerfile as 3-5i) so a fresh device does not fail (Session 7-2d).
if ! docker image inspect "${AGENT_IMAGE}" >/dev/null 2>&1; then
    info "image ${AGENT_IMAGE} not present yet — building it from agent/Dockerfile (stage 3-5i rebuilds it later)"
    docker build --quiet -t "${AGENT_IMAGE}" -f "${REPO_ROOT}/agent/Dockerfile" "${REPO_ROOT}/agent/" >/dev/null \
        || err "could not build ${AGENT_IMAGE} from ${REPO_ROOT}/agent/Dockerfile"
fi
ok "agent image ${AGENT_IMAGE} present"

# LAN IP for bind (policy needs DNS names; this is just for logging)
LAN_IP="$(ip -4 route get "${MAC_IP}" | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
[[ -n "${LAN_IP}" ]] || err "cannot determine LAN address used to reach the Mac"
ok "LAN address: ${LAN_IP}"

# The handoff file must exist UNLESS the edge-ingest provider already exists from a partial run
# (the file is deleted only after sandbox HTTP 200 in step 4, so if the provider exists but
# the file is gone, it means a previous run completed step 3 but dropped before step 4).
INGEST_PROVIDER_EXISTS=false
if openshell provider list 2>/dev/null | grep -q "^${INGEST_PROVIDER} "; then
    INGEST_PROVIDER_EXISTS=true
    info "provider ${INGEST_PROVIDER} already exists (partial re-run)"
    if ! sudocmd test -s "${HANDOFF_KEY}" 2>/dev/null; then
        info "handoff file already deleted — step 3+4 will be skipped (provider exists, file gone)"
    else
        info "handoff file still present — step 3 will skip provider create, step 4 will delete file"
    fi
else
    sudocmd test -s "${HANDOFF_KEY}" \
        || err "ingest key handoff file not found: ${HANDOFF_KEY} (and provider edge-ingest does not exist yet)"
    ok "ingest key handoff file present (root 0600)"
fi

# No existing providers — switching the credential driver requires none (docs + 14d line 218)
if openshell provider list 2>&1 | grep -vq "No providers found"; then
    info "Existing providers found:"
    openshell provider list 2>&1 | sed 's/^/    /'
    info "The Vault credential driver was already switched in an earlier run (idempotency)."
    info "Checking if driver is already active in gateway.toml..."
    if grep -q '^credential_drivers = \["vault"\]' "${GW_TOML}" 2>/dev/null; then
        info "Driver already permanent in gateway.toml — skipping Step 1 and probe."
        DRIVER_ALREADY_SET=true
    else
        DRIVER_ALREADY_SET=false
    fi
else
    DRIVER_ALREADY_SET=false
fi

# ── 1. Permanent Vault driver install ─────────────────────────────────────────
section "1. Vault credential driver — permanent install"

if [[ "${DRIVER_ALREADY_SET:-false}" == "true" ]]; then
    ok "gateway.toml already has credential_drivers=[\"vault\"] — skipping toml write and restart"
else
    # Take ownership of gateway.toml if root-owned (see 14d comment: root-owned inside a
    # jetson-owned directory; rename via temp file always works even when the file is root-owned)
    if [[ ! -w "${GW_TOML}" ]]; then
        info "${GW_TOML} not writable (owner: $(stat -c %U "${GW_TOML}")); taking ownership"
        echo "${SUDO_PASS:-}" | sudo -S chown "$(id -un):$(id -gn)" "${GW_TOML}"
        [[ -w "${GW_TOML}" ]] || err "cannot make ${GW_TOML} writable"
    fi
    [[ -f "${GW_BACKUP}" ]] || cp -p "${GW_TOML}" "${GW_BACKUP}"
    info "backed up existing gateway.toml to ${GW_BACKUP}"

    RESTORE_NEEDED=true
    # Apply the driver config
    if ! apply_driver; then
        err "failed to write the Vault-driver config to ${GW_TOML} — aborting (backup preserved at ${GW_BACKUP})"
    fi
    ok "gateway.toml written"

    # Verify the key is in the file
    grep -q '^credential_drivers = \["vault"\]' "${GW_TOML}" \
        || { put_toml_from "${GW_BACKUP}"; err "verification of credential_drivers line FAILED — config restored"; }
    grep -q "ca_bundle = \"${CA_COPY}\"" "${GW_TOML}" \
        || { put_toml_from "${GW_BACKUP}"; err "ca_bundle line missing from written config — restored"; }
    grep -q "token_path = \"${TOKEN_FILE}\"" "${GW_TOML}" \
        || { put_toml_from "${GW_BACKUP}"; err "token_path line missing from written config — restored"; }
    ok "three key lines verified in gateway.toml"

    # Preflight
    PF_OUT="$(openshell-gateway config preflight 2>&1)"; PF_RC=$?
    echo "${PF_OUT}" | sed 's/^/    | /'
    if [[ ${PF_RC} -ne 0 ]]; then
        put_toml_from "${GW_BACKUP}"
        systemctl --user restart openshell-gateway || true
        wait_gateway || true
        err "openshell-gateway config preflight FAILED (rc=${PF_RC}) — config restored from backup"
    fi
    ok "preflight passed"

    # Restart and wait for Connected
    GW_RESTART_AT="$(date '+%Y-%m-%d %H:%M:%S')"
    systemctl --user restart openshell-gateway
    if ! wait_gateway; then
        journalctl --user -u openshell-gateway --since "${GW_RESTART_AT}" --no-pager -n 15 | sed 's/^/    | /'
        put_toml_from "${GW_BACKUP}"
        systemctl --user restart openshell-gateway || true
        wait_gateway || true
        err "gateway did not reach Connected after restart — config restored from backup"
    fi
    ok "gateway Connected after restart (Vault credential driver active)"
    RESTORE_NEEDED=false
fi

# Verify the driver is actually talking to Vault by listing the managed prefix
info "verifying Vault connectivity via driver (list managed KV prefix)"
RESP_CODE="$(vcode "$(tok)" LIST "${MOUNT}/metadata/${KV_PREFIX}")"
# 404 = prefix exists but is empty; 200 = entries exist; both mean Vault is reachable
[[ "${RESP_CODE}" == "200" || "${RESP_CODE}" == "404" ]] \
    || err "unexpected HTTP ${RESP_CODE} from Vault — check the gateway token and mount path"
ok "Vault KV list returned HTTP ${RESP_CODE} (200=has entries, 404=empty prefix — both OK)"

# ── 2. Probe provider round-trip (dummy secret → Vault → delete) ──────────────
section "2. Probe provider round-trip (dummy secret)"

# Clean up any leftover probe profile/provider from a previous partial run
openshell provider delete "${PROBE_PROVIDER}" >/dev/null 2>&1 || true
openshell profile  delete "${PROBE_PROFILE}"  >/dev/null 2>&1 || true

# Create a minimal profile for the probe
cat > "${PROBE_PROFILE_YAML}" <<EOF
id: ${PROBE_PROFILE}
display_name: Stage 3-5h probe (dummy)
description: One-shot probe to verify the Vault driver round-trip — deleted at the end
category: other
credentials:
  - name: dummy_key
    description: Probe dummy credential
    env_vars: [PROBE_KEY]
    required: true
    auth_style: header
    header_name: X-Probe-Key
endpoints:
  - host: ${JETSON_HOSTNAME}
    port: ${TE_PORT}
    protocol: rest
    enforcement: enforce
    rules:
      - allow:
          method: GET
          path: /health
binaries:
  - /usr/bin/python3.12
EOF
openshell profile lint   -f "${PROBE_PROFILE_YAML}" 2>&1 | sed 's/^/    | /' || true
openshell profile import -f "${PROBE_PROFILE_YAML}" 2>&1 | sed 's/^/    | /' \
    || err "probe profile import failed"

KEYS_BEFORE="$(list_kv_keys)"
info "Vault KV keys before probe create: ${KEYS_BEFORE:-<none>}"

openshell provider create --name "${PROBE_PROVIDER}" --type "${PROBE_PROFILE}" \
    --credential "PROBE_KEY=${S1}" 2>&1 | sed 's/^/    | /' \
    || err "probe provider create failed"

KEYS_AFTER="$(list_kv_keys)"
info "Vault KV keys after probe create: ${KEYS_AFTER:-<none>}"

# Count entries: expect exactly one more than before
BEFORE_COUNT="$(tr ',' '\n' <<<"${KEYS_BEFORE:-}" | grep -c . || true)"
AFTER_COUNT="$(tr  ',' '\n' <<<"${KEYS_AFTER}"    | grep -c . || true)"
[[ "${AFTER_COUNT}" -gt "${BEFORE_COUNT}" ]] \
    || err "no new Vault entry appeared after probe provider create (before=${BEFORE_COUNT}, after=${AFTER_COUNT})"
ok "Vault KV entry created by probe provider (count: ${BEFORE_COUNT} → ${AFTER_COUNT})"

# Find the new key and verify the stored value
NEW_KEY=""
for k in ${KEYS_AFTER//,/ }; do
    if ! grep -qF "${k}" <<<"${KEYS_BEFORE:-}"; then
        NEW_KEY="${k}"; break
    fi
done
[[ -n "${NEW_KEY}" ]] || err "cannot identify which Vault key is new"
V1="$(vbody "$(tok)" GET "${MOUNT}/data/${KV_PREFIX}/${NEW_KEY}" | jget "data.data.value")"
[[ "${V1}" == "${S1}" ]] || err "Vault stored value does not match S1 (got: ${V1:-<empty>})"
ok "Vault holds S1 at path ${KV_PREFIX}/${NEW_KEY}"

# Delete and verify clean
openshell provider delete "${PROBE_PROVIDER}" 2>&1 | sed 's/^/    | /'
openshell profile  delete "${PROBE_PROFILE}"  2>&1 | sed 's/^/    | /'
KEYS_CLEAN="$(list_kv_keys)"
# NEW_KEY is the probe's key. It must be gone. Other keys (e.g. edge-ingest) may legitimately remain.
if grep -qF "${NEW_KEY}" <<<"${KEYS_CLEAN}"; then
    info "Remaining keys: ${KEYS_CLEAN}"
    warn "Probe key ${NEW_KEY} still in Vault after probe provider delete — possible stale entry"
else
    ok "Probe key removed from Vault after delete (clean round-trip); other pre-existing keys unaffected"
fi

# ── 3. Profile and provider: edge-ingest ──────────────────────────────────────
section "3. Profile edge-ingest + provider"

if ${INGEST_PROVIDER_EXISTS}; then
    ok "provider ${INGEST_PROVIDER} already exists — skipping profile import and provider create"
    # Identify the existing Vault key path for the summary
    INGEST_KEY_PATH="$(list_kv_keys | tr ',' '\n' | head -1)"
    ok "existing Vault path: ${KV_PREFIX}/${INGEST_KEY_PATH:-<see vault list>}"
else
    cat > "${INGEST_PROFILE_YAML}" <<EOF
id: ${INGEST_PROFILE}
display_name: Trusted Edge Ingest (API key)
description: X-Edge-Key header injection for trusted-edge.service (GET /frame.jpg, POST /events, POST /snapshot)
category: data
credentials:
  - name: ingest_key
    description: API key for trusted-edge; stored in Vault via the gateway Vault driver
    env_vars: [INGEST_KEY]
    required: true
    auth_style: header
    header_name: X-Edge-Key
endpoints:
  - host: ${JETSON_HOSTNAME}
    port: ${TE_PORT}
    protocol: rest
    enforcement: enforce
    rules:
      - allow:
          method: GET
          path: /frame.jpg
      - allow:
          method: POST
          path: /events
      - allow:
          method: POST
          path: /snapshot
binaries:
  - /usr/bin/python3.12
EOF
    openshell profile lint   -f "${INGEST_PROFILE_YAML}" 2>&1 | sed 's/^/    | /' || true
    openshell profile import -f "${INGEST_PROFILE_YAML}" 2>&1 | sed 's/^/    | /' \
        || err "profile ${INGEST_PROFILE} import failed"
    ok "profile ${INGEST_PROFILE} imported"

    # Read the plaintext ingest key from the handoff file AS ROOT; never print it.
    INGEST_KEY_VAL="$(sudocmd cat "${HANDOFF_KEY}" | tr -d '[:space:]')"
    [[ ${#INGEST_KEY_VAL} -eq 64 ]] \
        || err "handoff key is not 64 hex chars (got ${#INGEST_KEY_VAL}); file may be corrupt"

    KEYS_PRE_INGEST="$(list_kv_keys)"
    openshell provider create --name "${INGEST_PROVIDER}" --type "${INGEST_PROFILE}" \
        --credential "INGEST_KEY=${INGEST_KEY_VAL}" 2>&1 | sed 's/^/    | /' \
        || err "provider ${INGEST_PROVIDER} create failed"
    unset INGEST_KEY_VAL

    KEYS_POST_INGEST="$(list_kv_keys)"
    INGEST_KEY_PATH=""
    for k in ${KEYS_POST_INGEST//,/ }; do
        if ! grep -qF "${k}" <<<"${KEYS_PRE_INGEST:-}"; then
            INGEST_KEY_PATH="${k}"; break
        fi
    done
    [[ -n "${INGEST_KEY_PATH}" ]] || err "no new Vault entry for provider edge-ingest"
    ok "provider ${INGEST_PROVIDER} created — Vault path: ${KV_PREFIX}/${INGEST_KEY_PATH}"
fi

# Verify via a sandbox: GET /frame.jpg must return 200 with the provider-injected key.
cat > "${INGEST_POLICY}" <<'EOF'
version: 1
filesystem_policy:
  include_workdir: true
  read_only: [/usr, /lib, /bin, /etc, /proc, /var/log, /dev/urandom, /app, /opt/agent-venv]
  read_write: [/tmp, /dev/null]
landlock:
  compatibility: hard_requirement
process:
  run_as_user: "1000"
  run_as_group: "1000"
EOF
INGEST_CREATE_OUT="/tmp/ingest-verify-3-5h-create.out"
# < /dev/null: prevent sandbox create from touching the controlling TTY.
# 7-2e: the old `cmd || true; CRC=$?` always yielded 0 (the gate below was vacuous). `|| CRC=$?` keeps set -e
# quiet and still captures the real exit code.
INGEST_CRC=0
timeout 240 openshell sandbox create --name "${INGEST_SB}" --no-tty --detach \
    --from "${AGENT_IMAGE}" --policy "${INGEST_POLICY}" \
    --provider "${INGEST_PROVIDER}" -- sleep 600 < /dev/null > "${INGEST_CREATE_OUT}" 2>&1 || INGEST_CRC=$?
grep -v "Pulling image" "${INGEST_CREATE_OUT}" | sed 's/^/    create: /'
[[ ${INGEST_CRC} -eq 0 ]] || err "sandbox ${INGEST_SB} create failed (rc=${INGEST_CRC})"

for _ in $(seq 1 30); do
    PHASE="$(openshell sandbox list 2>&1 | awk -v n="${INGEST_SB}" '$1==n {print $NF}')"
    [[ "${PHASE}" == "Ready" ]] && break; sleep 2
done
[[ "${PHASE}" == "Ready" ]] || err "sandbox ${INGEST_SB} not Ready (phase=${PHASE:-unknown})"
ok "sandbox ${INGEST_SB} Ready"

# GET /frame.jpg — sandbox carries the X-Edge-Key placeholder; supervisor injects the real value.
PY_GET='import os,sys,urllib.request
req=urllib.request.Request("http://'"${JETSON_HOSTNAME}:${TE_PORT}"'/frame.jpg",headers={"X-Edge-Key":os.environ["INGEST_KEY"]})
try:
    r=urllib.request.urlopen(req, timeout=15)
    print("HTTP", r.status)
    sys.exit(0 if r.status==200 else 1)
except Exception as e:
    print("FAIL", type(e).__name__, str(e))
    sys.exit(1)'

GET_OUT="$(openshell sandbox exec -n "${INGEST_SB}" --no-tty --no-login-shell --timeout 30 -- \
    /usr/bin/python3.12 -c "${PY_GET}" < /dev/null 2>&1 || true)"
info "GET /frame.jpg from sandbox ${INGEST_SB}: ${GET_OUT}"
echo "${GET_OUT}" | grep -q "HTTP 200" \
    || err "GET /frame.jpg did not return 200 via provider ${INGEST_PROVIDER} (got: ${GET_OUT}); NOT deleting handoff file"

ok "GET /frame.jpg returned HTTP 200 through the edge-ingest provider (X-Edge-Key injected by the supervisor)"

# Delete sandbox (no longer needed for the verify step)
openshell sandbox delete "${INGEST_SB}" >/dev/null 2>&1 || true

# ── 4. Delete handoff file ONLY after verified ─────────────────────────────────
section "4. Delete handoff file"
sudocmd rm -f "${HANDOFF_KEY}"
# Also remove the parent dir if it only had the handoff file and is now empty
sudocmd rmdir /etc/trusted-edge 2>/dev/null || true
ok "handoff file deleted (the plaintext ingest key is now only in Vault via the gateway driver)"

# ── 5. Profile and provider: cosmos-vlm ──────────────────────────────────────
section "5. Profile cosmos-vlm + provider (inference, no credentials)"

VLM_PROVIDER_EXISTS=false
if openshell provider list 2>/dev/null | grep -q "^${VLM_PROVIDER} "; then
    VLM_PROVIDER_EXISTS=true
    ok "provider ${VLM_PROVIDER} already exists — skipping profile import and provider create"
fi

cat > "${VLM_PROFILE_YAML}" <<EOF
id: ${VLM_PROFILE}
display_name: Cosmos-Reason2-2B VLM (llama.cpp)
description: Inference provider profile for the local llama-server on :8090
category: inference
inference_capable: true
credentials: []
endpoints:
  - host: ${JETSON_HOSTNAME}
    port: ${VLM_PORT}
    protocol: rest
    enforcement: enforce
    rules:
      - allow:
          method: POST
          path: /v1/chat/completions
      - allow:
          method: GET
          path: /health
binaries:
  - /usr/bin/python3.12
EOF
if ! ${VLM_PROVIDER_EXISTS}; then
    openshell profile lint   -f "${VLM_PROFILE_YAML}" 2>&1 | sed 's/^/    | /' || true
    openshell profile import -f "${VLM_PROFILE_YAML}" 2>&1 | sed 's/^/    | /' \
        || err "profile ${VLM_PROFILE} import failed"
    ok "profile ${VLM_PROFILE} imported"

    # Provider with no credentials (credentials: [] so we do not need --credential)
    openshell provider create --name "${VLM_PROVIDER}" --type "${VLM_PROFILE}" 2>&1 | sed 's/^/    | /' \
        || err "provider ${VLM_PROVIDER} create failed"
    ok "provider ${VLM_PROVIDER} created (no credentials)"
fi

# Verify: GET /health from inside a sandbox carrying cosmos-vlm must return 200.
cat > "${VLM_POLICY}" <<'EOF'
version: 1
filesystem_policy:
  include_workdir: true
  read_only: [/usr, /lib, /bin, /etc, /proc, /var/log, /dev/urandom, /app, /opt/agent-venv]
  read_write: [/tmp, /dev/null]
landlock:
  compatibility: hard_requirement
process:
  run_as_user: "1000"
  run_as_group: "1000"
EOF
VLM_CREATE_OUT="/tmp/vlm-verify-3-5h-create.out"
VLM_CRC=0
timeout 240 openshell sandbox create --name "${VLM_SB}" --no-tty --detach \
    --from "${AGENT_IMAGE}" --policy "${VLM_POLICY}" \
    --provider "${VLM_PROVIDER}" -- sleep 600 < /dev/null > "${VLM_CREATE_OUT}" 2>&1 || VLM_CRC=$?
grep -v "Pulling image" "${VLM_CREATE_OUT}" | sed 's/^/    create: /'
[[ ${VLM_CRC} -eq 0 ]] || err "sandbox ${VLM_SB} create failed (rc=${VLM_CRC})"

for _ in $(seq 1 30); do
    VPHASE="$(openshell sandbox list 2>&1 | awk -v n="${VLM_SB}" '$1==n {print $NF}')"
    [[ "${VPHASE}" == "Ready" ]] && break; sleep 2
done
[[ "${VPHASE}" == "Ready" ]] || err "sandbox ${VLM_SB} not Ready (phase=${VPHASE:-unknown})"
ok "sandbox ${VLM_SB} Ready"

PY_HEALTH='import urllib.request
try:
    r=urllib.request.urlopen("http://'"${JETSON_HOSTNAME}:${VLM_PORT}"'/health", timeout=15)
    print("HTTP", r.status)
except Exception as e:
    print("FAIL", type(e).__name__, str(e))'
HEALTH_OUT="$(openshell sandbox exec -n "${VLM_SB}" --no-tty --no-login-shell --timeout 30 -- \
    /usr/bin/python3.12 -c "${PY_HEALTH}" < /dev/null 2>&1 || true)"
info "GET /health from sandbox ${VLM_SB}: ${HEALTH_OUT}"
echo "${HEALTH_OUT}" | grep -q "HTTP 200" \
    || err "GET /health did not return 200 via provider ${VLM_PROVIDER} (got: ${HEALTH_OUT})"
ok "GET /health returned HTTP 200 through the cosmos-vlm provider"
openshell sandbox delete "${VLM_SB}" >/dev/null 2>&1 || true

# ── 6. `openshell policy get --full` for both providers ──────────────────────
section "6. Effective policy check for both providers (openshell policy get --full)"
info "Creating a combined sandbox with both providers to read the effective policy"
BOTH_SB="both-3h-${_SFX}"
BOTH_POLICY="/tmp/policy-both-3-5h.yaml"
cat > "${BOTH_POLICY}" <<'EOF'
version: 1
filesystem_policy:
  include_workdir: true
  read_only: [/usr, /lib, /bin, /etc, /proc, /var/log, /dev/urandom, /app, /opt/agent-venv]
  read_write: [/tmp, /dev/null]
landlock:
  compatibility: hard_requirement
process:
  run_as_user: "1000"
  run_as_group: "1000"
EOF
BOTH_CREATE_OUT="/tmp/both-verify-3-5h-create.out"
BOTH_CRC=0
timeout 240 openshell sandbox create --name "${BOTH_SB}" --no-tty --detach \
    --from "${AGENT_IMAGE}" --policy "${BOTH_POLICY}" \
    --provider "${INGEST_PROVIDER}" --provider "${VLM_PROVIDER}" \
    -- sleep 600 < /dev/null > "${BOTH_CREATE_OUT}" 2>&1 || BOTH_CRC=$?
grep -v "Pulling image" "${BOTH_CREATE_OUT}" | sed 's/^/    create: /'
if [[ ${BOTH_CRC} -eq 0 ]]; then
    for _ in $(seq 1 30); do
        BPHASE="$(openshell sandbox list 2>&1 | awk -v n="${BOTH_SB}" '$1==n {print $NF}')"
        [[ "${BPHASE}" == "Ready" ]] && break; sleep 2
    done
    if [[ "${BPHASE}" == "Ready" ]]; then
        EFFECTIVE_POLICY="$(openshell policy get "${BOTH_SB}" --full 2>&1)"
        echo "${EFFECTIVE_POLICY}" | sed 's/^/    | /'
        # The gateway substitutes hyphens with underscores in provider rule names.
        _INGEST_RULE="_provider_${INGEST_PROVIDER//-/_}"
        _VLM_RULE="_provider_${VLM_PROVIDER//-/_}"
        echo "${EFFECTIVE_POLICY}" | grep -q "${_INGEST_RULE}" \
            && ok "effective policy contains ${_INGEST_RULE}" \
            || warn "effective policy does NOT contain ${_INGEST_RULE} — check output above"
        echo "${EFFECTIVE_POLICY}" | grep -q "${_VLM_RULE}" \
            && ok "effective policy contains ${_VLM_RULE}" \
            || warn "effective policy does NOT contain ${_VLM_RULE} — check output above"
    else
        warn "both-provider sandbox not Ready (phase=${BPHASE:-unknown}) — skipping policy get"
    fi
else
    warn "both-provider sandbox create failed — skipping policy get"
fi
openshell sandbox delete "${BOTH_SB}" >/dev/null 2>&1 || true
rm -f "${BOTH_POLICY}"

# ── 7. Measure `provider update` Vault path (open item from 3-5d F4) ──────────
section "7. Measure where provider update stores the rotated value in Vault"
# We use the edge-ingest provider (already has a real credential) but rotate to a
# DUMMY value here just to observe the path behaviour; we rotate BACK immediately.
info "recording Vault key(s) BEFORE update (open item from 3-5d F4: new path vs new version?)"
KEYS_BEFORE_UPD="$(list_kv_keys)"
info "keys before update: ${KEYS_BEFORE_UPD:-<none>}"

# Find the current edge-ingest handle key
INGEST_HANDLE_KEY=""
for k in ${KEYS_BEFORE_UPD//,/ }; do
    INGEST_HANDLE_KEY="${k}"   # there should be exactly one
    break
done

# To observe the update behaviour we need a second dummy secret and a provider we can freely rotate.
# Use a throw-away provider instance to avoid touching the real edge-ingest credential.
THROW_AWAY_PROVIDER="throw-3h-${_SFX}"

openshell provider create --name "${THROW_AWAY_PROVIDER}" --type "${INGEST_PROFILE}" \
    --credential "INGEST_KEY=${S1}" >/dev/null 2>&1 || true

KEYS_WITH_THROW="$(list_kv_keys)"
THROW_KEY=""
for k in ${KEYS_WITH_THROW//,/ }; do
    already=false
    for p in ${KEYS_BEFORE_UPD//,/ }; do [[ "${k}" == "${p}" ]] && already=true && break; done
    if ! ${already}; then THROW_KEY="${k}"; break; fi
done
[[ -n "${THROW_KEY}" ]] || { warn "could not identify throw-away provider key — skipping update path measurement"; \
    openshell provider delete "${THROW_AWAY_PROVIDER}" >/dev/null 2>&1 || true; }

if [[ -n "${THROW_KEY}" ]]; then
    info "throw-away provider key before update: ${THROW_KEY}"
    # Update to S2
    openshell provider update "${THROW_AWAY_PROVIDER}" --credential "INGEST_KEY=${S2}" --wait --timeout 60 \
        2>&1 | sed 's/^/    | /' || true
    KEYS_AFTER_UPD="$(list_kv_keys)"
    info "keys after update: ${KEYS_AFTER_UPD:-<none>}"

    # Is the old key still there?
    if grep -qF "${THROW_KEY}" <<<"${KEYS_AFTER_UPD}"; then
        OLD_VER="$(vbody "$(tok)" GET "${MOUNT}/metadata/${KV_PREFIX}/${THROW_KEY}" | jget "data.current_version")"
        OLD_VAL="$(vbody "$(tok)" GET "${MOUNT}/data/${KV_PREFIX}/${THROW_KEY}" | jget "data.data.value")"
        if [[ "${OLD_VAL}" == "${S2}" ]]; then
            ok "provider update: SAME KEY ${THROW_KEY} — update is a versioned write (current_version=${OLD_VER}); old S1 overwritten with S2"
            echo "    provider_update_path_observation: SAME_PATH new_version=${OLD_VER}" \
                | tee /tmp/provider-update-observation.txt
        else
            info "old key ${THROW_KEY} still present (current_version=${OLD_VER}) but holds ${OLD_VAL} (not S2)"
            # Find where S2 is
            for k in ${KEYS_AFTER_UPD//,/ }; do
                V="$(vbody "$(tok)" GET "${MOUNT}/data/${KV_PREFIX}/${k}" | jget "data.data.value")"
                if [[ "${V}" == "${S2}" ]]; then
                    ok "provider update: NEW KEY ${k} — update writes to a new path; old key ${THROW_KEY} remains (stale)"
                    echo "    provider_update_path_observation: NEW_PATH old_key_remains=${THROW_KEY} new_key=${k}" \
                        | tee /tmp/provider-update-observation.txt
                    break
                fi
            done
        fi
    else
        # Old key gone — S2 must be under a new key
        for k in ${KEYS_AFTER_UPD//,/ }; do
            already=false
            for p in ${KEYS_BEFORE_UPD//,/ }; do [[ "${k}" == "${p}" ]] && already=true && break; done
            if ! ${already}; then
                ok "provider update: NEW KEY ${k} — old key ${THROW_KEY} REMOVED; no stale copy in Vault"
                echo "    provider_update_path_observation: NEW_PATH_OLD_REMOVED old_key=${THROW_KEY} new_key=${k}" \
                    | tee /tmp/provider-update-observation.txt
                break
            fi
        done
    fi
    openshell provider delete "${THROW_AWAY_PROVIDER}" >/dev/null 2>&1 || true
    if [[ -f /tmp/provider-update-observation.txt ]]; then
        info "provider update observation: $(cat /tmp/provider-update-observation.txt)"
        ok "3-5d F4 open item: provider update path measured (see above)"
    else
        warn "could not determine the provider update path — check Vault KV manually"
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
section "RESULT"
echo
echo "  gateway.toml          Vault driver permanent (credential_drivers=[\"vault\"])"
echo "  ca_bundle             ${CA_COPY}"
echo "  token_path            ${TOKEN_FILE}"
echo "  mount                 ${MOUNT}"
echo "  profile edge-ingest   endpoints: jetson.localdomain:${TE_PORT} (GET /frame.jpg, POST /events, POST /snapshot)"
echo "  provider edge-ingest  Vault path: ${KV_PREFIX}/${INGEST_KEY_PATH:-<see above>}"
echo "  profile cosmos-vlm    inference_capable:true, endpoints: jetson.localdomain:${VLM_PORT}"
echo "  provider cosmos-vlm   no credentials (open endpoint profile)"
echo "  handoff file          deleted (key now only in Vault)"
echo "  gate HTTP 200         GET /frame.jpg via edge-ingest provider: ✓"
echo "  gate HTTP 200         GET /health via cosmos-vlm provider:     ✓"
echo
ok "Stage 3-5h complete (marker 13a_gateway_vault_driver is written by setup-jetson.sh)"
