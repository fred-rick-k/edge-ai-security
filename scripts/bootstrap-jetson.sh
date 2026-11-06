#!/usr/bin/env bash
# scripts/bootstrap-jetson.sh
# Mac-side launcher: syncs the repo to the Jetson and kicks off setup-jetson.sh.
#
# Usage:
#   ./scripts/bootstrap-jetson.sh [jetson-ip|user@jetson-ip]      # run ALL pending stages (default dependency order)
#   ./scripts/bootstrap-jetson.sh [jetson-ip] --reset-all         # lists + confirms, deletes the ingest-key chain
#                                                                 #   (Jetson sandbox/providers/profiles, Mac KV hash
#                                                                 #   edge-device/ingest-key), removes ALL markers, then
#                                                                 #   runs the default order (Session 7-2d)
#   ./scripts/bootstrap-jetson.sh [jetson-ip] --reset-all --no-run # same reset, then STOPS (does not run the default
#                                                                 #   order). First half of a fresh start; the Mac KV
#                                                                 #   step needs the OLD Vault still up (Session 7-2e)
#   ./scripts/bootstrap-jetson.sh [jetson-ip] --phase 2           # run all pending stages for Phase 2
#   ./scripts/bootstrap-jetson.sh [jetson-ip] --only-stage 2-1   # run ONLY Phase 2 Stage 1 (WebUI install)
#   ./scripts/bootstrap-jetson.sh [jetson-ip] --reset-stage 2-1  # delete marker, then re-run stage 2-1
#   ./scripts/bootstrap-jetson.sh [jetson-ip] --cleanup           # revert all stages
#   ./scripts/bootstrap-jetson.sh [jetson-ip] --cleanup --phase 2 # revert Phase 2 only
#   ./scripts/bootstrap-jetson.sh [jetson-ip] --cleanup --full    # revert + delete repo
#
# Phase & Stage Mapping:
#   Phase 1 (VLM Server on :8090):
#     1-1 (prep)        → 01_prep          env prep, headless, clocks, swap
#     1-2 (model)       → 03_*             Cosmos-Reason2-2B GGUF + llama.cpp pull
#     1-3 (vlm)         → 08_services      vlm-server.service install
#     1-4 (vlm-smoke)   → (no marker)      inference smoke test (always re-runs)
#   Phase 2 (Live VLM WebUI on :8443):
#     2-1 (webui)       → 09_webui         live-vlm-webui.service install
#     2-2 (webui-smoke) → (no marker)      WebUI verification & smoke test (always re-runs)
#   Phase 3 (OpenShell Sandbox):
#     3-1 (openshell)   → 10_openshell     OpenShell supervisor install + policy
#     3-2 (openshell-test) → (no marker)   REAL policy test of the running camera-agent sandbox
#                                           (run after 3-5i; always re-runs; writes no audit log)
#     3-3 (openshell-ui) → (no new marker)  OpenShell demo UI card (re-deploys
#                                           live-vlm-webui, marker 09_webui)
#     3-4a (sandbox-smoke) → (no marker)    REAL sandbox smoke test (always re-runs)
#     3-4b (agent-sandbox-test) → (no marker) agent image + sandbox under agent/policy.yaml
#     3-5a (provider-probe) → (no marker)   measure provider-injected X-Vault-Token header
#     3-5c (provider-update-probe) → (no marker) does `provider update` reach a RUNNING sandbox process?
#     3-5d (gateway-vault-driver-probe) → (no marker) probe the gateway `vault` credential driver
#     3-5g (trusted-edge)    → 13_trusted_edge       trusted-edge.service (camera + DEK + DB holder)
#     3-5h (gateway-vault-driver) → 13a_gateway_vault_driver  permanent Vault driver + providers
#                                           edge-ingest and cosmos-vlm; handoff file deleted
#     3-5i (agent-sandbox)        → 13b_agent_sandbox          persistent camera-agent sandbox
#     3-5j (camera-credential)    → 14_camera_credential       retires config/camera.env (template -> LoadCredential=)
#     3-5j2a (vlm-memory-probe)   → (no marker)                READ-ONLY vlm-server memory/swap measurement
#     3-5j2b (wifi-off)           → (no marker)                Wi-Fi radio off + autoconnect off, verified
#     3-5j2c (ingest-key-resync)  → (no marker)                provider edge-ingest <- key trusted-edge accepts
#   Phase 5 (End-to-End Integration):
#     5-1 (tpm-agent)         → 11_tpm_agent            vault-agent (edge role, mode 0640 root:edge-ingest)
#     5-1b (tpm-gateway-agent) → 11b_tpm_gateway_agent   vault-agent-gateway (gateway role, mode 0640 root:jetson)
#     5-2 (agent-pipeline)    → 12_agent_pipeline       Transit datakey + dynamic DB creds + agent deps
#     5-3b (vault-widgets)    → 15_vault_widgets        Tab-1 Vault widgets (identity, Rotate Secret Now, payload decrypt);
#                                                       pushes ONLY control-plane-reader role_id+secret_id from the Mac server

set -euo pipefail

# ── load & validate .env ──────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ ! -f "${REPO_ROOT}/.env" ]]; then
  echo "ERROR: .env file not found at ${REPO_ROOT}/.env" >&2
  echo "       Please copy .env.example to .env and configure your environment:" >&2
  echo "       cp .env.example .env" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090,SC1091
source "${REPO_ROOT}/.env"
set +a

REQUIRED_VARS=(
  JETSON_IP
  JETSON_USER
  JETSON_HOSTNAME
  JETSON_SSH_KEY
  MAC_IP
  MAC_USER
  MAC_HOSTNAME
  MAC_SSH_KEY
  VAULT_PORT
  VAULT_ADDR
  POSTGRES_PORT
  POSTGRES_DB
  VLM_PORT
  TRUSTED_EDGE_PORT
  WEBUI_PORT
  DISABLE_WIFI
)

# Session 7-2e: POSTGRES_USER, POSTGRES_PASSWORD and CAMERA_RTSP_URL are NOT required here. The Jetson never
# uses them (the allow-listed .env push below omits them); scripts/bootstrap-mac.sh checks them on the Mac side.
for v in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    echo "ERROR: Required environment variable '${v}' is missing or empty in .env" >&2
    exit 1
  fi
done

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
  VAULT_LICENSE="$(cat "${RESOLVED_VL_PATH}")"
  export VAULT_LICENSE
elif [[ -n "${VL_STR}" ]]; then
  VAULT_LICENSE="${VL_STR}"
  export VAULT_LICENSE
fi

# ── config ────────────────────────────────────────────────────────────────────
REMOTE_DIR="edge-device-demo"          # relative to $HOME on Jetson
KEY_FILE="${JETSON_SSH_KEY/#\~/$HOME}"
MAC_SERVER="${MAC_USER}@${MAC_IP}"
MAC_SERVER_CERT="${MAC_SSH_KEY/#\~/$HOME}"

# ── parse args ────────────────────────────────────────────────────────────────
CLI_TARGET=""
CLEANUP=false
CLEANUP_FULL=false
RESET_STAGE=""
RESET_ALL=false
NO_RUN=false
CLEANUP_STAGE=""
CLEANUP_PHASE=""
ONLY_STAGE=""
PHASE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cleanup)        CLEANUP=true ; shift ;;
    --full)           CLEANUP_FULL=true ; shift ;;
    --phase)          PHASE="$2" ; shift 2 ;;
    --phase=*)        PHASE="${1#--phase=}" ; shift ;;
    --stage)          CLEANUP_STAGE="$2" ; CLEANUP=true ; shift 2 ;;
    --stage=*)        CLEANUP_STAGE="${1#--stage=}" ; CLEANUP=true ; shift ;;
    --reset-all)      RESET_ALL=true ; shift ;;
    --no-run)         NO_RUN=true ; shift ;;
    --reset-stage)    RESET_STAGE="$2" ; shift 2 ;;
    --reset-stage=*)  RESET_STAGE="${1#--reset-stage=}" ; shift ;;
    --only-stage)     ONLY_STAGE="$2" ; shift 2 ;;
    --only-stage=*)   ONLY_STAGE="${1#--only-stage=}" ; shift ;;
    --*)              echo "Unknown flag: $1"; exit 1 ;;
    *)                [[ -z "${CLI_TARGET}" ]] && CLI_TARGET="$1" ; shift ;;
  esac
done

# Target is `host` or `user@host`. JETSON_USER from .env is the default user; an explicit
# `user@` prefix overrides it. The host is everything after the LAST '@', so JETSON_HOST is
# built exactly once below (never `user@user@host`).
if [[ -n "${CLI_TARGET}" ]]; then
  if [[ "${CLI_TARGET}" == *"@"* ]]; then
    _CLI_USER="${CLI_TARGET%@*}"
    JETSON_IP="${CLI_TARGET##*@}"
    [[ -n "${_CLI_USER}" ]] && JETSON_USER="${_CLI_USER}"
    unset _CLI_USER
  else
    JETSON_IP="${CLI_TARGET}"
  fi
  if [[ -z "${JETSON_IP}" ]]; then
    echo "ERROR: empty host in target argument '${CLI_TARGET}' (expected <host> or <user>@<host>)" >&2
    exit 1
  fi
fi

if [[ "${NO_RUN}" == "true" && "${RESET_ALL}" != "true" ]]; then
  echo "ERROR: --no-run is only valid together with --reset-all." >&2
  exit 1
fi

if [[ "${RESET_ALL}" == "true" ]] && \
   { [[ "${CLEANUP}" == "true" ]] || [[ -n "${RESET_STAGE}${ONLY_STAGE}${PHASE}" ]]; }; then
  echo "ERROR: --reset-all runs the full default order; it cannot be combined with --cleanup, --reset-stage, --only-stage or --phase." >&2
  exit 1
fi

# --reset-stage without --only-stage: infer --only-stage from the reset target
if [[ -n "${RESET_STAGE}" && -z "${ONLY_STAGE}" ]]; then
  ONLY_STAGE="${RESET_STAGE}"
fi

if [[ -z "${JETSON_IP}" ]]; then
  read -rp "Jetson IP address or hostname: " JETSON_IP
fi
JETSON_HOST="${JETSON_USER}@${JETSON_IP}"

echo "==> Bootstrapping Jetson at ${JETSON_HOST}"

# ── SSH options + control master socket ──────────────────────────────────────
SOCKET_DIR="${TMPDIR:-/tmp}/jetson-ssh-$$"
mkdir -p "${SOCKET_DIR}"
SOCKET="${SOCKET_DIR}/ctl"
CM_OPTS="-o ControlMaster=auto -o ControlPath=${SOCKET} -o ControlPersist=600"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=30 \
  -o ServerAliveInterval=15 -o ServerAliveCountMax=8 \
  ${CM_OPTS} -i ${KEY_FILE}"

# Ensure the control socket is closed on exit (normal or error)
cleanup_socket() {
  ssh -O exit -o ControlPath="${SOCKET}" "${JETSON_HOST}" 2>/dev/null || true
  rm -rf "${SOCKET_DIR}"
}
trap cleanup_socket EXIT

# ── generate SSH key if needed ────────────────────────────────────────────────
if [[ ! -f "${KEY_FILE}" ]]; then
  echo "--> Generating SSH key ${KEY_FILE} ..."
  ssh-keygen -t ed25519 -f "${KEY_FILE}" -N "" -C "jetson-demo"
fi

# ── install SSH key on Jetson (prompts for SSH password exactly once) ─────────
if ! ssh -o BatchMode=yes -o ControlPath="${SOCKET}" -o ControlMaster=auto \
        -o ConnectTimeout=30 -i "${KEY_FILE}" \
        -o StrictHostKeyChecking=accept-new \
        "${JETSON_HOST}" "true" 2>/dev/null; then
  echo "--> Installing SSH key on Jetson (enter SSH password once)..."
  ssh-copy-id -i "${KEY_FILE}.pub" \
    -o StrictHostKeyChecking=accept-new \
    "${JETSON_HOST}"
  echo "    SSH key installed. Future runs will not ask for SSH password."
else
  echo "--> SSH key already accepted by Jetson."
fi

# ── open persistent control master connection ────────────────────────────────
echo "--> Opening persistent SSH connection..."
# shellcheck disable=SC2086
ssh ${SSH_OPTS} "${JETSON_HOST}" "true"
echo "    Connection established (socket: ${SOCKET})"

# ── prompt for Jetson sudo password (once, on the Mac) ───────────────────────
echo
echo "Enter the Jetson sudo password."
echo "(Stored only in memory for this session, passed to the remote script.)"
read -rsp "Jetson sudo password: " SUDO_PASS
echo

# Validate by piping the password over SSH stdin
# shellcheck disable=SC2086
if ! printf '%s\n' "${SUDO_PASS}" | \
     ssh ${SSH_OPTS} "${JETSON_HOST}" "sudo -S true 2>/dev/null"; then
  echo "ERROR: sudo password invalid on Jetson."
  exit 1
fi
echo "--> Credentials verified."

# ── sync repo via rsync (reuses control master socket) ───────────────────────
echo "--> Syncing repository to ${JETSON_HOST}:~/${REMOTE_DIR} ..."
rsync -avz --delete \
  -e "ssh ${SSH_OPTS}" \
  --exclude='.git/' \
  --exclude='.bob/' \
  --exclude='.DS_Store' \
  --exclude='*.pyc' \
  --exclude='__pycache__/' \
  --exclude='.venv/' \
  --exclude='ui/.venv/' \
  --exclude='node_modules/' \
  --exclude='external/' \
  --exclude='checkpoints/' \
  --exclude='engines/' \
  --exclude='models/' \
  --exclude='data/' \
  --exclude='tls/' \
  --exclude='source/' \
  --exclude='config/camera.env' \
  --exclude='.env' \
  --exclude='.setup-state/' \
  "${REPO_ROOT}/" \
  "${JETSON_HOST}:~/${REMOTE_DIR}/"

# The full .env holds secrets the Jetson never uses (CAMERA_RTSP_URL, POSTGRES_PASSWORD, VAULT_LICENSE_*);
# syncing it put the camera credential on the device (found by the stage 3-5g scan, 2026-11-03, 7-2d).
# Push an allow-listed copy instead: only the keys the Jetson-side scripts read. rsync --delete does not
# touch an excluded file, so this also overwrites a full .env left there by an earlier sync.
JETSON_ENV_KEYS='JETSON_IP|JETSON_USER|JETSON_HOSTNAME|MAC_IP|MAC_USER|MAC_HOSTNAME|VAULT_PORT|VAULT_ADDR|POSTGRES_PORT|POSTGRES_DB|VLM_PORT|TRUSTED_EDGE_PORT|WEBUI_PORT|DISABLE_WIFI'
JETSON_ENV_TMP="$(mktemp)"
grep -E "^(${JETSON_ENV_KEYS})=" "${REPO_ROOT}/.env" > "${JETSON_ENV_TMP}" || true
chmod 600 "${JETSON_ENV_TMP}"
# shellcheck disable=SC2086
rsync -az -e "ssh ${SSH_OPTS}" "${JETSON_ENV_TMP}" "${JETSON_HOST}:~/${REMOTE_DIR}/.env"
rm -f "${JETSON_ENV_TMP}"
echo "--> .env: pushed $(printf '%s' "${JETSON_ENV_KEYS}" | awk -F'|' '{print NF}') allow-listed keys only (no camera URL, DB password or licence)."

echo "--> Sync complete."

# ── copy Vault TLS CA cert to Jetson ─────────────────────────────────────────
# tls/vault.crt is the public cert — safe to distribute, but per deployment (made by vault/gen-tls.sh) and not in git.
# tls/vault.key stays on the Mac server only (in .gitignore).
# The rsync above excludes tls/ to avoid accidentally syncing the private key,
# so we copy just vault.crt explicitly here.
# MAC_SERVER and MAC_SERVER_CERT are configured from .env above

# Ensure the cert exists locally (it's committed to the repo; fetch from Mac
# server as a fallback in case local workspace is stale).
if [[ ! -f "${REPO_ROOT}/tls/vault.crt" ]]; then
  echo "--> tls/vault.crt missing locally — fetching from Mac server (${MAC_SERVER})..."
  mkdir -p "${REPO_ROOT}/tls"
  scp -i "${MAC_SERVER_CERT}" \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 \
    "${MAC_SERVER}:~/edge-device-demo/tls/vault.crt" \
    "${REPO_ROOT}/tls/vault.crt" 2>/dev/null || \
    echo "--> WARNING: could not fetch tls/vault.crt from Mac server — Stage 5-1 may fail."
fi

if [[ -f "${REPO_ROOT}/tls/vault.crt" ]]; then
  echo "--> Copying tls/vault.crt to Jetson (CA cert for VAULT_CACERT)..."
  # shellcheck disable=SC2086
  ssh ${SSH_OPTS} "${JETSON_HOST}" "mkdir -p ~/${REMOTE_DIR}/tls"
  # shellcheck disable=SC2086
  rsync -az -e "ssh ${SSH_OPTS}" \
    "${REPO_ROOT}/tls/vault.crt" \
    "${JETSON_HOST}:~/${REMOTE_DIR}/tls/vault.crt"
  echo "--> tls/vault.crt copied."
else
  echo "--> WARNING: tls/vault.crt not found — Stage 5-1 will fail without it."
fi

# ── make stage scripts executable ────────────────────────────────────────────
# shellcheck disable=SC2086
ssh ${SSH_OPTS} "${JETSON_HOST}" "chmod +x ~/${REMOTE_DIR}/scripts/*.sh"

# ── write password to a remote temp file ─────────────────────────────────────
# shellcheck disable=SC2086
REMOTE_PASS_FILE="$(printf '%s' "${SUDO_PASS}" | \
  ssh ${SSH_OPTS} "${JETSON_HOST}" \
  'f=$(mktemp /tmp/.sp.XXXXXX); chmod 600 "$f"; cat > "$f"; echo "$f"')"

cleanup_remote_pass() {
  # shellcheck disable=SC2086
  ssh ${SSH_OPTS} "${JETSON_HOST}" "rm -f '${REMOTE_PASS_FILE}'" 2>/dev/null || true
}
trap 'cleanup_socket; cleanup_remote_pass' EXIT

# ── ensure persistent swap is active ─────────────────────────────────────────
if [[ "${CLEANUP}" != "true" ]]; then
  echo "--> Ensuring persistent swap..."
  # shellcheck disable=SC2086
  ssh ${SSH_OPTS} "${JETSON_HOST}" \
    "export SUDO_PASS=\"\$(cat '${REMOTE_PASS_FILE}')\"; bash ~/${REMOTE_DIR}/scripts/ensure-swap.sh"
  echo
fi

# ── optional: reset a single stage marker before running setup ───────────────
if [[ -n "${RESET_STAGE}" ]]; then
  case "${RESET_STAGE}" in
    1|1-1|prep)                        MARKER="01_prep" ;;
    3|1-2|model|3a)                    MARKER="03_download_model" ;;
    3b)                                MARKER="03_pull_container" ;;
    4|1-3|vlm|vlm-server)              MARKER="08_services" ;;
    2|2-1|webui|webui-server)          MARKER="09_webui" ;;
    5|1-4|smoke)                       MARKER="" ;;  # smoke test has no marker
    3-1|10_openshell|openshell)        MARKER="10_openshell" ;;
    3-4a|sandbox-smoke)                MARKER="" ;;  # no marker
    3-4b|agent-sandbox-test)           MARKER="" ;;  # no marker
    3-5a|provider-probe)               MARKER="" ;;  # no marker
    3-5c|provider-update-probe)        MARKER="" ;;  # no marker
    3-5d|gateway-vault-driver-probe)   MARKER="" ;;  # no marker
    3-5g|13_trusted_edge|trusted-edge) MARKER="13_trusted_edge" ;;
    3-5h|13a_gateway_vault_driver|gateway-vault-driver) MARKER="13a_gateway_vault_driver" ;;
    3-5i|13b_agent_sandbox|agent-sandbox) MARKER="13b_agent_sandbox" ;;
    3-5j|14_camera_credential|camera-credential) MARKER="14_camera_credential" ;;
    3-5j2a|vlm-memory-probe)           MARKER="" ;;  # no marker
    3-5j2b|wifi-off)                   MARKER="" ;;  # no marker
    3-5j2c|ingest-key-resync)          MARKER="" ;;  # no marker
    5-1|11_tpm_agent|tpm-agent|tpm|tpm-enroll) MARKER="11_tpm_agent" ;;
    5-1b|11b_tpm_gateway_agent|tpm-gateway-agent|gateway-agent|gateway-tpm) MARKER="11b_tpm_gateway_agent" ;;
    5-2|12_agent_pipeline|agent-pipeline|data-pipeline) MARKER="12_agent_pipeline" ;;
    5-3b|15_vault_widgets|vault-widgets) MARKER="15_vault_widgets" ;;
    *)                                 MARKER="${RESET_STAGE}" ;;  # pass raw marker name
  esac
  if [[ -n "${MARKER}" ]]; then
    echo "--> Resetting stage marker: ${MARKER}"
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "${JETSON_HOST}" \
      "rm -f ~/${REMOTE_DIR}/.setup-state/${MARKER} && echo 'Marker removed: ${MARKER}' || echo 'Marker not found: ${MARKER}'"
  fi
fi

# ── --reset-all: delete the ingest-key chain + all markers (Session 7-2d, user decisions 2026-11-03) ───
# Why markers alone are not enough (read from scripts 13/15/16, not run): 3-5h deletes the ingest-key handoff
# file, so a re-run of 3-5g generates a NEW key and aborts with EXISTS_DIFFERENT against the create-only
# SHA-256 in Vault KV edge-ai-demo-kv/edge-device/ingest-key; provider edge-ingest and sandbox camera-agent
# would still hold the old key.  So reset-all deletes, in this order (each step stops the launcher on failure;
# ONE typed confirmation, RESET, covers all three steps because the prompt lists them - user decision 2026-11-03):
#   1. Jetson: sandbox camera-agent (+ te-src-probe), providers + profiles edge-ingest, cosmos-vlm
#      (deleting a provider removes the gateway's KV entry in Vault through the Vault driver)
#   2. Mac:    Vault KV edge-ai-demo-kv/edge-device/ingest-key (that ONE path; root token read on the Mac,
#              never printed, never leaves the Mac)
#   3. Jetson: every marker in .setup-state/
# Kept: /etc/webui-vault/admin-key and its KV hash (5-3b reuses them), models, venvs, units, TPM state.
if [[ "${RESET_ALL}" == "true" ]]; then
  _RA_EXPORT="export SUDO_PASS=\"\$(cat '${REMOTE_PASS_FILE}')\""
  _RA_CMD="~/${REMOTE_DIR}/scripts/reset-all.sh"
  echo
  echo "════════════════ --reset-all on ${JETSON_HOST} ════════════════"
  # shellcheck disable=SC2086
  ssh ${SSH_OPTS} "${JETSON_HOST}" "${_RA_EXPORT}; ${_RA_CMD} list"
  echo "Also (Mac ${MAC_SERVER}, after the Jetson chain is deleted): delete Vault KV edge-ai-demo-kv/edge-device/ingest-key"
  echo "  (the SHA-256 of the ingest key; nothing else in Vault is deleted)."
  echo "Afterwards the default stage order runs from scratch; stages re-install over the existing device state."
  echo
  read -rp "Type RESET to delete ALL items above (Jetson chain, Mac KV hash, Jetson markers; anything else aborts): " _ANS
  [[ "${_ANS}" == "RESET" ]] || { echo "Aborted; nothing changed."; exit 1; }

  echo "--> Jetson: deleting the ingest-key chain..."
  # shellcheck disable=SC2086
  ssh ${SSH_OPTS} "${JETSON_HOST}" "${_RA_EXPORT}; ${_RA_CMD} chain" \
    || { echo "ERROR: Jetson chain deletion failed; markers and Vault untouched."; exit 1; }

  echo "--> Mac: deleting the ingest-key hash (root token read on the Mac, not printed)..."
  ssh -i "${MAC_SERVER_CERT}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${MAC_SERVER}" 'bash -s' <<'MACEOF' \
    || { echo "ERROR: Vault KV deletion failed on the Mac; Jetson markers NOT removed."; exit 1; }
set -euo pipefail
cd ~/edge-device-demo
export PATH=/opt/homebrew/bin:$PATH VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=tls/vault.crt
VAULT_TOKEN="$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('~/edge-device-demo/.vault-keys.json')))['root_token'])")"
export VAULT_TOKEN
P=edge-device/ingest-key
if vault kv metadata get -mount=edge-ai-demo-kv "$P" >/dev/null 2>&1; then
  vault kv metadata delete -mount=edge-ai-demo-kv "$P"
else
  echo "KV $P not present (nothing to delete)"
fi
if vault kv metadata get -mount=edge-ai-demo-kv "$P" >/dev/null 2>&1; then
  echo "ERROR: KV $P still present after delete" >&2; exit 1
fi
echo "verified: KV edge-ai-demo-kv/$P is absent"
MACEOF

  echo "--> Jetson: removing all stage markers..."
  # shellcheck disable=SC2086
  ssh ${SSH_OPTS} "${JETSON_HOST}" "${_RA_EXPORT}; ${_RA_CMD} markers" \
    || { echo "ERROR: marker removal failed."; exit 1; }
  unset _ANS _RA_EXPORT _RA_CMD
  if [[ "${NO_RUN}" == "true" ]]; then
    echo "--> reset-all done (--no-run): the default order was NOT started. Nothing was installed or re-created."
    exit 0
  fi
  echo "--> reset-all done; running the default order."
  echo
fi

# ── Stage 5-3b: hand the control-plane-reader AppRole credential to the Jetson ───────────────────────
# ONLY role_id + secret_id leave the Mac server (never the root token, never the rest of .vault-keys.json).
# They travel Mac server -> this machine (memory, a pipe) -> Jetson over ssh stdin into a 0600 temp file whose
# path is exported as CONTROL_READER_FILE; scripts/21-vault-widgets.sh installs it root-only and deletes it.
CONTROL_READER_EXPORT=""
# Staged for --only-stage 5-3b, and for the default order (no --only-stage/--phase) when the marker is absent
# (setup-jetson.sh runs 5-3b in the default order and removes the staged files if it skips).
_STAGE_CR=false
case "${ONLY_STAGE}" in
  5-3b|15_vault_widgets|vault-widgets) _STAGE_CR=true ;;
  "")
    if [[ -z "${PHASE}" && "${CLEANUP}" != "true" ]]; then
      # shellcheck disable=SC2086
      ssh ${SSH_OPTS} "${JETSON_HOST}" "test -f ~/${REMOTE_DIR}/.setup-state/15_vault_widgets" || _STAGE_CR=true
    fi
    ;;
esac
case "${_STAGE_CR}" in
  true)
    if [[ "${CLEANUP}" != "true" ]]; then
      echo "--> Stage 5-3b: fetching control-plane-reader role_id/secret_id from ${MAC_SERVER} (nothing else)..."
      CR_JSON="$(ssh -i "${MAC_SERVER_CERT}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${MAC_SERVER}" \
        "python3 -c \"import json, os; d=json.load(open(os.path.expanduser('~/edge-device-demo/.vault-keys.json')))['control_plane_reader']; print(json.dumps({'role_id':d['role_id'],'secret_id':d['secret_id']}))\"")" \
        || { echo "ERROR: could not read control_plane_reader from the Mac server (run 'make setup-control-reader' there first)."; exit 1; }
      # shellcheck disable=SC2086
      REMOTE_CR_FILE="$(printf '%s' "${CR_JSON}" | ssh ${SSH_OPTS} "${JETSON_HOST}" \
        'f=$(mktemp /tmp/.cr.XXXXXX); chmod 600 "$f"; cat > "$f"; echo "$f"')"
      unset CR_JSON

      echo "--> Stage 5-3b: staging Mac SSH private key on Jetson..."
      # shellcheck disable=SC2086
      REMOTE_MK_FILE="$(cat "${MAC_SERVER_CERT}" | ssh ${SSH_OPTS} "${JETSON_HOST}" \
        'f=$(mktemp /tmp/.mk.XXXXXX); chmod 600 "$f"; cat > "$f"; echo "$f"')"

      CONTROL_READER_EXPORT="; export CONTROL_READER_FILE='${REMOTE_CR_FILE}'; export MAC_KEY_FILE='${REMOTE_MK_FILE}'"
      echo "--> control-plane-reader credential staged on the Jetson at ${REMOTE_CR_FILE} (0600)"
      echo "--> Mac SSH private key staged on the Jetson at ${REMOTE_MK_FILE} (0600)"
    fi
    ;;
esac

# ── set Vault address + CA cert path for Phase 5 stages ──────────────────────
# Vault serves https (TLS required for auth/tpm/login).
# vault.crt was copied explicitly above (not via rsync — tls/ is excluded to
# avoid accidentally syncing the private key).
PHASE5_EXPORTS="export VAULT_ADDR=${VAULT_ADDR}; export VAULT_CACERT=\${HOME}/${REMOTE_DIR}/tls/vault.crt"
echo "--> Vault address set for Stage 5-1: ${VAULT_ADDR}"
echo "    CA cert: ~/edge-device-demo/tls/vault.crt (copied explicitly above)"

# ── hand off: cleanup or setup ───────────────────────────────────────────────
_BASE_EXPORT="export SUDO_PASS=\"\$(cat '${REMOTE_PASS_FILE}')\""
if [[ -n "${PHASE5_EXPORTS}" ]]; then
  REMOTE_EXPORT="${_BASE_EXPORT}; ${PHASE5_EXPORTS}${CONTROL_READER_EXPORT}"
else
  REMOTE_EXPORT="${_BASE_EXPORT}${CONTROL_READER_EXPORT}"
fi
if [[ "${CLEANUP}" == "true" ]]; then
  CLEANUP_ARGS=""
  [[ "${CLEANUP_FULL}" == "true" ]] && CLEANUP_ARGS="${CLEANUP_ARGS} --full"
  [[ -n "${CLEANUP_STAGE}" ]]       && CLEANUP_ARGS="${CLEANUP_ARGS} --stage ${CLEANUP_STAGE}"
  [[ -n "${PHASE}" ]]               && CLEANUP_ARGS="${CLEANUP_ARGS} --phase ${PHASE}"
  CLEANUP_ARGS="${CLEANUP_ARGS# }"
  echo "--> Running cleanup-jetson.sh on Jetson${CLEANUP_ARGS:+ (${CLEANUP_ARGS})}..."
  echo
  # shellcheck disable=SC2086
  ssh -t ${SSH_OPTS} "${JETSON_HOST}" \
    "${REMOTE_EXPORT}; ~/${REMOTE_DIR}/scripts/cleanup-jetson.sh ${CLEANUP_ARGS}"
else
  SETUP_ARGS=""
  if [[ -n "${ONLY_STAGE}" ]]; then
    SETUP_ARGS="--only-stage ${ONLY_STAGE}"
  elif [[ -n "${PHASE}" ]]; then
    SETUP_ARGS="--phase ${PHASE}"
  fi

  echo "--> Executing setup-jetson.sh ${SETUP_ARGS} on Jetson..."
  echo
  # shellcheck disable=SC2086
  ssh -t ${SSH_OPTS} "${JETSON_HOST}" \
    "${REMOTE_EXPORT}; ~/${REMOTE_DIR}/scripts/setup-jetson.sh ${SETUP_ARGS}"
fi

echo
echo "==> Done.  Connect with:"
echo "    ssh -i ${KEY_FILE} ${JETSON_HOST}"
