#!/usr/bin/env bash
# scripts/17-camera-credential.sh
# ──────────────────────────────────────────────────────────────────────────────
# Phase 3 Stage 3-5j (camera-credential) — marker 14_camera_credential.
#
# Retires config/camera.env for the WebUI (user requirement 2026-10-17).  Design
# (phase-prompts-v2.md section 2, "WebUI REQUIREMENT"):
#   edge vault-agent `template` renders the RTSP URL from Vault KV
#   edge-ai-demo-kv/edge-device/camera-creds to a root-only file on tmpfs
#   (/run/webui-camera/camera-rtsp-url, 0600)  ->  live-vlm-webui.service receives it with
#   LoadCredential=  ->  ui/server.py reads $CREDENTIALS_DIRECTORY/camera-rtsp-url.
#   The WebUI keeps its direct RTSP stream (no frame pulling, no proxy hop, no 3rd vault-agent).
#
# Documentation read BEFORE writing this (AGENTS.md 0.1 rule 6):
#   Vault Agent templates   https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent/template
#       template options: contents|source, destination, perms, backup (default TRUE), exec,
#       error_on_missing_key, create_dest_dirs; template_config.exit_on_retry_failure (default false);
#       KV v2 is re-rendered every static_secret_render_interval (default 5m); `exec` runs only when the
#       rendered output changed.  There is NO owner/group option -> the file is root-owned, mode 0600.
#   systemd.exec(5) on the device (systemd 255): LoadCredential=ID:PATH is read when the UNIT STARTS,
#       exposed read-only under $CREDENTIALS_DIRECTORY, accessible to the unit's User= and root only;
#       the SOURCE file need only be readable by the service manager.
#
# What this stage MEASURES (the six open points of the design; each prints its own verdict):
#   P1 owner/group/perms of the rendered file and of the delivered credential
#   P2 the vault-agent never logs the URL (secret_scan over the journal since stage start)
#   P3 how a (re)rendered URL reaches the WebUI: template `exec` restarts the unit
#      (first render measured; a CHANGED URL in Vault is NOT exercised here -> "not run", needs a Mac KV write)
#   P4 the file survives a vault-agent restart (reboot NOT exercised -> "not run")
#   P5 WebUI frame rate before / after (frame_count delta from /api/status)
#   P6 coupling: break the template on purpose (read of a path the edge policy does not allow);
#      token sink must still be rewritten, vault-agent must stay up, trusted-edge must keep working
# Then: delete config/camera.env and run edge/secret_scan.py WITHOUT --known (must be zero hits).
#
# Fails closed: if any change cannot be applied or any measurement fails, the stage exits non-zero and
# restores the previous vault-agent HCL where it had changed it.
#
# Usage: ./scripts/bootstrap-jetson.sh <jetson-ip> --only-stage 3-5j
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${REPO_DIR}/.setup-state"
MARKER="${STATE_DIR}/14_camera_credential"

AGENT_HCL="/etc/vault-agent/vault-agent.hcl"
AGENT_SVC="vault-agent"
DEST_DIR="/run/webui-camera"
DEST_FILE="${DEST_DIR}/camera-rtsp-url"
KV_PATH="edge-ai-demo-kv/data/edge-device/camera-creds"
CRED_ID="camera-rtsp-url"
WEBUI_SVC="live-vlm-webui"
WEBUI_STATUS="https://127.0.0.1:8443/api/status"
VA_DROPIN_DIR="/etc/systemd/system/${AGENT_SVC}.service.d"
VA_DROPIN="${VA_DROPIN_DIR}/20-webui-camera-dir.conf"
WEBUI_DROPIN_DIR="/etc/systemd/system/${WEBUI_SVC}.service.d"
WEBUI_DROPIN="${WEBUI_DROPIN_DIR}/10-camera-credential.conf"
INSTALL_DIR="/opt/trusted-edge"
VENV="${INSTALL_DIR}/venv"
TOKEN_SINK="/run/openshell-edge/vault-token"
CAMERA_ENV="${REPO_DIR}/config/camera.env"
BEGIN_MARK="# BEGIN webui-camera-template (Session 3-5j)"
END_MARK="# END webui-camera-template (Session 3-5j)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}  ▷ $*${NC}"; }
ok()      { echo -e "${GREEN}  ✓ $*${NC}"; }
warn()    { echo -e "${YELLOW}  ⚠ $*${NC}"; }
err()     { echo -e "${RED}  ✗ $*${NC}"; exit 1; }
section() { echo -e "\n${GREEN}══ $* ══${NC}"; }
sudocmd() { echo "${SUDO_PASS}" | sudo -S "$@"; }

STAGE_START="$(date '+%Y-%m-%d %H:%M:%S')"
HCL_BACKUP=""          # set when we changed the HCL; used by the restore trap
BROKEN_ACTIVE=false    # true while the deliberately broken template is installed
TMPFILES=()

restore_on_exit() {
    local rc=$?
    for f in "${TMPFILES[@]:-}"; do [[ -n "${f}" ]] && rm -f "${f}"; done
    if ${BROKEN_ACTIVE} && [[ -n "${HCL_BACKUP}" ]] && sudocmd test -f "${HCL_BACKUP}.broken-test"; then
        warn "exiting while the deliberately broken template is installed — restoring the working HCL"
        sudocmd cp -p "${HCL_BACKUP}.broken-test" "${AGENT_HCL}" && sudocmd systemctl restart "${AGENT_SVC}" || true
    fi
    if [[ ${rc} -ne 0 && -n "${HCL_BACKUP}" && "${RESTORE_HCL_ON_FAIL:-false}" == "true" ]]; then
        warn "stage failed before camera.env was retired — restoring ${AGENT_HCL} from ${HCL_BACKUP} and removing the WebUI credential drop-in"
        sudocmd cp -p "${HCL_BACKUP}" "${AGENT_HCL}" || true
        sudocmd rm -f "${WEBUI_DROPIN}" "${VA_DROPIN}" || true
        sudocmd systemctl daemon-reload || true
        sudocmd systemctl restart "${AGENT_SVC}" || true
        warn "NOTE: ui/server.py on the device no longer reads config/camera.env; a WebUI restart without the credential drop-in shows the synthetic pattern."
    fi
}
trap restore_on_exit EXIT

if [[ -f "${MARKER}" ]]; then
    echo -e "${GREEN}Stage 3-5j already complete (marker exists). Skipping.${NC}"
    exit 0
fi

# ── 0. Entry checks ───────────────────────────────────────────────────────────
section "0. Entry checks"
[[ -f "${STATE_DIR}/11_tpm_agent" ]]    || err "Stage 5-1 (11_tpm_agent) not complete."
[[ -f "${STATE_DIR}/13_trusted_edge" ]] || err "Stage 3-5g (13_trusted_edge) not complete (needs ${INSTALL_DIR}/secret_scan.py)."
: "${VAULT_ADDR:?VAULT_ADDR must be set (bootstrap)}"
: "${VAULT_CACERT:?VAULT_CACERT must be set (bootstrap)}"
systemctl is-active --quiet "${AGENT_SVC}"  || err "${AGENT_SVC}.service is not active"
systemctl is-active --quiet trusted-edge    || err "trusted-edge.service is not active"
systemctl is-active --quiet "${WEBUI_SVC}"  || err "${WEBUI_SVC}.service is not active — nothing to measure"
sudocmd test -s "${TOKEN_SINK}"             || err "edge token missing at ${TOKEN_SINK}"
sudocmd test -x "${VENV}/bin/python"        || err "${VENV}/bin/python missing (stage 3-5g)"
sudocmd test -f "${INSTALL_DIR}/secret_scan.py" || err "${INSTALL_DIR}/secret_scan.py missing (stage 3-5g)"
sudocmd test -f "${AGENT_HCL}"              || err "${AGENT_HCL} missing"
[[ -f "${REPO_DIR}/ui/server.py" ]] && grep -q "CREDENTIALS_DIRECTORY" "${REPO_DIR}/ui/server.py" \
    || err "ui/server.py on this device does not read \$CREDENTIALS_DIRECTORY (rsync of the new code missing?)"
ok "vault-agent, trusted-edge, ${WEBUI_SVC} active; edge token present; new ui/server.py present"
info "vault: $(/usr/local/bin/vault version 2>/dev/null | head -1)"

frame_count() {
    curl -sk --max-time 5 "${WEBUI_STATUS}" \
        | python3 -c "import json,sys; c=json.load(sys.stdin)['camera']; print(c['frame_count'], c['is_synthetic'])"
}
measure_fps() {   # $1 = seconds ; prints "fps synthetic"
    local a b t0 t1 syn
    read -r a syn < <(frame_count); t0=$(date +%s.%N)
    sleep "$1"
    read -r b _   < <(frame_count); t1=$(date +%s.%N)
    [[ -n "${a}" && -n "${b}" ]] || { echo "WebUI /api/status unreadable" >&2; return 1; }
    awk -v a="$a" -v b="$b" -v t0="$t0" -v t1="$t1" -v s="$syn" 'BEGIN{printf "%.2f %s", (b-a)/(t1-t0), s}'
}
webui_active_ts() { systemctl show -p ActiveEnterTimestampMonotonic --value "${WEBUI_SVC}"; }
file_sha() { sudocmd sha256sum "$1" | awk '{print $1}'; }
url_sha_of_file() {   # sha256 of the stripped content (never prints content)
    sudocmd cat "$1" | python3 -c "import sys,hashlib; print(hashlib.sha256(sys.stdin.read().strip().encode()).hexdigest())"
}

# ── 1. P5 BEFORE ──────────────────────────────────────────────────────────────
section "1. P5 — WebUI frame rate BEFORE (process as currently running)"
FPS_BEFORE="$(measure_fps 30)"
ok "WebUI frame_count rate BEFORE: ${FPS_BEFORE% *} /s over 30 s (is_synthetic=${FPS_BEFORE#* })"
[[ "${FPS_BEFORE#* }" == "False" ]] || warn "WebUI is on the SYNTHETIC fallback before the change — the comparison is not about the real camera"
FILE_PREEXISTED=false
sudocmd test -s "${DEST_FILE}" && FILE_PREEXISTED=true
info "rendered file already present from an earlier run: ${FILE_PREEXISTED}"

# ── 2. systemd drop-ins ───────────────────────────────────────────────────────
section "2. systemd drop-ins (directory for the rendered file; LoadCredential= for the WebUI)"
# /run/webui-camera is NOT a RuntimeDirectory of vault-agent: RuntimeDirectoryMode= is one value for all
# listed directories and would make it 0755.  ExecStartPre creates it 0700 root on every (re)start / boot.
VA_TMP="$(mktemp)"; TMPFILES+=("${VA_TMP}")
cat > "${VA_TMP}" <<EOF
# Session 3-5j: root-only tmpfs directory for the rendered camera URL (template destination).
[Service]
ExecStartPre=/usr/bin/install -d -m 0700 -o root -g root ${DEST_DIR}
EOF
sudocmd install -d -m 0755 "${VA_DROPIN_DIR}"
sudocmd install -m 0644 -o root -g root "${VA_TMP}" "${VA_DROPIN}"

WU_TMP="$(mktemp)"; TMPFILES+=("${WU_TMP}")
cat > "${WU_TMP}" <<EOF
# Session 3-5j: the camera RTSP URL arrives as a systemd credential; config/camera.env is retired.
# The source file is rendered by vault-agent (template stanza) to tmpfs, root 0600.
# If the file does not exist yet (early boot) the unit fails to start and Restart=on-failure retries every 5 s.
[Unit]
After=${AGENT_SVC}.service
Wants=${AGENT_SVC}.service

[Service]
LoadCredential=${CRED_ID}:${DEST_FILE}
EOF
sudocmd install -d -m 0755 "${WEBUI_DROPIN_DIR}"
sudocmd install -m 0644 -o root -g root "${WU_TMP}" "${WEBUI_DROPIN}"
sudocmd systemctl daemon-reload
ok "drop-ins installed: ${VA_DROPIN} , ${WEBUI_DROPIN}"
sudocmd install -d -m 0700 -o root -g root "${DEST_DIR}"

# Measurement of the failure mode when the credential SOURCE is missing (what a boot race would hit).
info "measuring what systemd does when the LoadCredential source file is missing (transient unit, User=jetson)"
MISS_OUT="$(sudocmd systemd-run --wait --collect -p User=jetson \
    -p "LoadCredential=probe:/run/webui-camera/does-not-exist-$$" /bin/true 2>&1 || true)"
echo "${MISS_OUT}" | sed 's/^/    | /'

# ── 3. vault-agent template ───────────────────────────────────────────────────
section "3. Add template + template_config to ${AGENT_HCL}"
HCL_BACKUP="${AGENT_HCL}.pre-3-5j"
if sudocmd grep -qF "${BEGIN_MARK}" "${AGENT_HCL}"; then
    info "${AGENT_HCL} already carries the template block — leaving it"
    HAD_BLOCK=true
else
    HAD_BLOCK=false
    sudocmd cp -p "${AGENT_HCL}" "${HCL_BACKUP}"
    HCL_TMP="$(mktemp)"; TMPFILES+=("${HCL_TMP}")
    sudocmd cat "${AGENT_HCL}" > "${HCL_TMP}"
    cat >> "${HCL_TMP}" <<EOF

${BEGIN_MARK}
# exit_on_retry_failure stays false (the default): a broken template must never kill token renewal
# (measured in this stage, point P6).
template_config {
  exit_on_retry_failure = false
}

template {
  contents             = "{{ with secret \"${KV_PATH}\" }}{{ .Data.data.rtsp_url }}{{ end }}"
  destination          = "${DEST_FILE}"
  perms                = "0600"
  backup               = false
  create_dest_dirs     = false
  error_on_missing_key = true
  exec {
    command = ["/usr/bin/systemctl", "restart", "--no-block", "${WEBUI_SVC}.service"]
    timeout = "30s"
  }
}
${END_MARK}
EOF
    sudocmd cp "${HCL_TMP}" "${AGENT_HCL}"
    sudocmd chown root:root "${AGENT_HCL}"; sudocmd chmod 600 "${AGENT_HCL}"
    sudocmd grep -qF "${BEGIN_MARK}" "${AGENT_HCL}" || { sudocmd cp -p "${HCL_BACKUP}" "${AGENT_HCL}"; err "HCL edit did not apply — restored"; }
    ok "template block appended (backup ${HCL_BACKUP})"
fi
${HAD_BLOCK} || RESTORE_HCL_ON_FAIL=true
WEBUI_TS_BEFORE="$(webui_active_ts)"
RESTART_AT="$(date '+%Y-%m-%d %H:%M:%S')"
info "restarting ${AGENT_SVC} (TPM re-auth + first render)"
sudocmd systemctl restart "${AGENT_SVC}"
for _ in $(seq 1 90); do sudocmd test -s "${DEST_FILE}" && break; sleep 1; done
if ! sudocmd test -s "${DEST_FILE}"; then
    sudocmd journalctl -u "${AGENT_SVC}" --since "${RESTART_AT}" --no-pager -o cat | tail -20 | sed 's/^/    | /'
    err "no rendered file at ${DEST_FILE} within 90 s — vault-agent journal above (restoring the previous HCL)"
fi
systemctl is-active --quiet "${AGENT_SVC}" || err "${AGENT_SVC} is not active after adding the template"
sudocmd test -s "${TOKEN_SINK}" || err "token sink missing after adding the template"
ok "vault-agent active; token sink present; ${DEST_FILE} rendered"

# ── 4. P1 permissions / ownership ─────────────────────────────────────────────
section "4. P1 — owner / group / perms"
D_STAT="$(sudocmd stat -c '%a %U:%G' "${DEST_DIR}")"
F_STAT="$(sudocmd stat -c '%a %U:%G' "${DEST_FILE}")"
info "directory ${DEST_DIR}: ${D_STAT}   |   file ${DEST_FILE}: ${F_STAT}   |   fs: $(sudocmd stat -f -c '%T' "${DEST_FILE}")"
[[ "${F_STAT%% *}" == "600" ]] || err "rendered file mode is ${F_STAT%% *}, expected 600"
[[ "$(sudocmd stat -f -c '%T' "${DEST_FILE}")" == "tmpfs" ]] || err "${DEST_FILE} is not on tmpfs"
[[ "${F_STAT#* }" == root:* ]] || err "rendered file is not root-owned (${F_STAT#* })"
for u in jetson edge-ingest nobody; do
    if sudocmd -u "${u}" test -r "${DEST_FILE}" 2>/dev/null; then err "user ${u} can read ${DEST_FILE}"; fi
done
ok "P1 verified: root-owned 0600 on tmpfs; jetson, edge-ingest and nobody cannot read the source file"
sudocmd ls -la "${DEST_DIR}" | sed 's/^/    | /'
[[ -z "$(sudocmd find "${DEST_DIR}" -mindepth 1 ! -name "$(basename "${DEST_FILE}")")" ]] \
    && ok "no backup/extra file next to the rendered file (backup=false)" \
    || err "extra files in ${DEST_DIR} (backup copy?)"

# ── 5. P3 how the URL reaches the WebUI ───────────────────────────────────────
section "5. P3 — template exec restarts the WebUI on a first render"
if ${FILE_PREEXISTED}; then
    info "file existed before this run: an unchanged render must NOT restart the unit (re-run case)"
    sleep 10
    if [[ "$(webui_active_ts)" == "${WEBUI_TS_BEFORE}" ]]; then
        ok "P3 (partial): unchanged render did not restart the WebUI"
    else
        warn "WebUI was restarted although the rendered content was unchanged — exec fires on agent restart too"
    fi
else
    for _ in $(seq 1 45); do
        [[ "$(webui_active_ts)" != "${WEBUI_TS_BEFORE}" ]] && break; sleep 1
    done
    [[ "$(webui_active_ts)" != "${WEBUI_TS_BEFORE}" ]] \
        || err "P3 FAILED: the template exec did not restart ${WEBUI_SVC} within 45 s of the first render"
    ok "P3 verified for the first render: the exec block restarted ${WEBUI_SVC}"
fi
for _ in $(seq 1 40); do systemctl is-active --quiet "${WEBUI_SVC}" && curl -sk -o /dev/null --max-time 3 "https://127.0.0.1:8443/health" && break; sleep 1; done
systemctl is-active --quiet "${WEBUI_SVC}" || { sudocmd journalctl -u "${WEBUI_SVC}" -n 20 --no-pager | sed 's/^/    | /'; err "${WEBUI_SVC} not active"; }
WPID="$(systemctl show -p MainPID --value "${WEBUI_SVC}")"
CRED_DIR_ENV="$(tr '\0' '\n' < "/proc/${WPID}/environ" | sed -n 's/^CREDENTIALS_DIRECTORY=//p')"
[[ -n "${CRED_DIR_ENV}" ]] || err "WebUI process has no CREDENTIALS_DIRECTORY — LoadCredential= not applied"
info "WebUI CREDENTIALS_DIRECTORY=${CRED_DIR_ENV}"
sudocmd ls -la "${CRED_DIR_ENV}" | sed 's/^/    | /'
CRED_STAT="$(sudocmd stat -c '%a %U:%G' "${CRED_DIR_ENV}/${CRED_ID}")"
info "delivered credential: ${CRED_STAT}"
[[ "$(url_sha_of_file "${CRED_DIR_ENV}/${CRED_ID}")" == "$(url_sha_of_file "${DEST_FILE}")" ]] \
    || err "delivered credential differs from the rendered file"
ok "credential delivered by systemd and identical to the rendered file"
if [[ -f "${CAMERA_ENV}" ]]; then
    ENV_SHA="$(python3 - "${CAMERA_ENV}" <<'PY'
import hashlib, re, sys
for line in open(sys.argv[1]):
    m = re.match(r'\s*RTSP_STREAM_1\s*=\s*"?([^"\n]*)"?\s*$', line)
    if m:
        print(hashlib.sha256(m.group(1).strip().encode()).hexdigest()); break
PY
)"
    if [[ -n "${ENV_SHA}" && "${ENV_SHA}" == "$(url_sha_of_file "${DEST_FILE}")" ]]; then
        ok "the URL rendered from Vault is identical to RTSP_STREAM_1 in config/camera.env (hashes compared, nothing printed)"
    else
        warn "the URL rendered from Vault DIFFERS from config/camera.env (or RTSP_STREAM_1 not found) — the WebUI will use the Vault one"
    fi
fi

# ── 6. P4 survives a vault-agent restart ──────────────────────────────────────
section "6. P4 — file survives a vault-agent restart"
SHA_PRE="$(file_sha "${DEST_FILE}")"; MT_PRE="$(sudocmd stat -c %Y "${DEST_FILE}")"
WEBUI_TS_PRE="$(webui_active_ts)"
R4_AT="$(date '+%Y-%m-%d %H:%M:%S')"
sudocmd systemctl restart "${AGENT_SVC}"
sleep 25
systemctl is-active --quiet "${AGENT_SVC}" || err "P4: ${AGENT_SVC} not active after restart"
sudocmd test -s "${DEST_FILE}" || err "P4 FAILED: ${DEST_FILE} gone after a vault-agent restart"
SHA_POST="$(file_sha "${DEST_FILE}")"
[[ "${SHA_PRE}" == "${SHA_POST}" ]] || err "P4 FAILED: content changed across a vault-agent restart"
ok "P4 verified for a service restart: file present, content unchanged, mtime ${MT_PRE} -> $(sudocmd stat -c %Y "${DEST_FILE}")"
if [[ "$(webui_active_ts)" == "${WEBUI_TS_PRE}" ]]; then
    ok "an unchanged render after an agent restart does NOT restart the WebUI (exec fires on change only)"
else
    warn "the WebUI was restarted by the vault-agent restart (exec ran although the content was identical)"
fi
warn "NOT RUN: survival across a reboot (the directory is recreated by ExecStartPre; the WebUI retries until the file exists) — needs a reboot, check afterwards with: systemctl status ${WEBUI_SVC}"
warn "NOT RUN: a CHANGED URL in Vault reaching the WebUI (needs a KV write on the Mac; render interval 5 m, then the exec restart)"

# ── 7. P6 coupling: break the template on purpose ─────────────────────────────
section "7. P6 — coupling: a broken template must not stop token renewal"
[[ "$(sudocmd grep -cF "${KV_PATH}" "${AGENT_HCL}")" == "1" ]] || err "expected exactly one occurrence of ${KV_PATH} in ${AGENT_HCL}"
sudocmd cp -p "${AGENT_HCL}" "${HCL_BACKUP}.broken-test"
BROKEN_ACTIVE=true
sudocmd sed -i "s#${KV_PATH}#edge-ai-demo-kv/data/edge-device/not-allowed-by-policy#" "${AGENT_HCL}"
sudocmd grep -qF "not-allowed-by-policy" "${AGENT_HCL}" || err "could not install the broken template"
SHA_BEFORE_BROKEN="$(file_sha "${DEST_FILE}")"
B_EPOCH="$(date +%s)"; B_AT="$(date '+%Y-%m-%d %H:%M:%S')"
sudocmd systemctl restart "${AGENT_SVC}"
info "waiting 50 s with the broken template installed"
sleep 50
B_ACTIVE="$(systemctl is-active "${AGENT_SVC}" || true)"
B_TOKEN_MT="$(sudocmd stat -c %Y "${TOKEN_SINK}" 2>/dev/null || echo 0)"
B_ERRS="$(sudocmd journalctl -u "${AGENT_SVC}" --since "${B_AT}" --no-pager -o cat | grep -ciE "template|permission denied|error" || true)"
B_TOKEN_OK="no"
TOK="$(sudocmd cat "${TOKEN_SINK}" 2>/dev/null || true)"
if [[ -n "${TOK}" ]]; then
    # token goes to curl on stdin (-H @-), never on the command line
    CODE="$(printf 'X-Vault-Token: %s\n' "${TOK}" | curl -s -o /dev/null -w '%{http_code}' --cacert "${VAULT_CACERT}" -H @- "${VAULT_ADDR}/v1/auth/token/lookup-self" || echo 000)"
    [[ "${CODE}" == "200" ]] && B_TOKEN_OK="yes (lookup-self 200)" || B_TOKEN_OK="no (HTTP ${CODE})"
fi
unset TOK
B_SHA_SAME="no"; [[ "$(file_sha "${DEST_FILE}")" == "${SHA_BEFORE_BROKEN}" ]] && B_SHA_SAME="yes"
B_TE="$(systemctl is-active trusted-edge || true)"
B_REQS="$(sudocmd journalctl -u trusted-edge --since "${B_AT}" --no-pager -o cat | grep -c "req client=" || true)"
B_TE_ERR="$(sudocmd journalctl -u trusted-edge --since "${B_AT}" --no-pager -o cat | grep -ciE "DB insert failed|vault.*(denied|failed)|traceback" || true)"
echo "    vault-agent state            : ${B_ACTIVE}"
echo "    template-related log lines   : ${B_ERRS}"
echo "    token sink rewritten         : mtime ${B_TOKEN_MT} (>= restart ${B_EPOCH}: $([[ ${B_TOKEN_MT} -ge ${B_EPOCH} ]] && echo yes || echo no))"
echo "    token in sink is valid       : ${B_TOKEN_OK}"
echo "    old rendered file kept       : ${B_SHA_SAME}"
echo "    trusted-edge state           : ${B_TE}; requests served in window: ${B_REQS}; error lines: ${B_TE_ERR}"
# restore the working template right away
sudocmd cp -p "${HCL_BACKUP}.broken-test" "${AGENT_HCL}"
BROKEN_ACTIVE=false
sudocmd rm -f "${HCL_BACKUP}.broken-test"
sudocmd systemctl restart "${AGENT_SVC}"
for _ in $(seq 1 60); do sudocmd test -s "${DEST_FILE}" && sudocmd test -s "${TOKEN_SINK}" && break; sleep 1; done
sleep 5
sudocmd grep -qF "${KV_PATH}" "${AGENT_HCL}" || err "working template NOT restored"
[[ "$(file_sha "${DEST_FILE}")" == "${SHA_BEFORE_BROKEN}" ]] || err "rendered file changed after restoring the template"
systemctl is-active --quiet "${AGENT_SVC}" || err "${AGENT_SVC} not active after restoring the template"
ok "working template restored; vault-agent active; rendered file unchanged"
[[ "${B_ACTIVE}" == "active" ]] || err "P6 FAILED: vault-agent was not running with a broken template (exit_on_retry_failure=false)"
[[ ${B_TOKEN_MT} -ge ${B_EPOCH} && "${B_TOKEN_OK}" == yes* ]] || err "P6 FAILED: token sink not renewed/valid with a broken template"
[[ "${B_TE}" == "active" ]] || err "P6 FAILED: trusted-edge stopped"
ok "P6 verified: with exit_on_retry_failure=false a failing template leaves token renewal and trusted-edge intact"
warn "NOT MEASURED: exit_on_retry_failure=true (documented: the agent exits on template failure -> would take the token with it); deliberately left false"

# ── 8. retire camera.env, P5 AFTER, P2 scan ───────────────────────────────────
# From here on camera.env is deleted: a failure no longer reverts the template (that would leave the WebUI
# with no camera source at all).
RESTORE_HCL_ON_FAIL=false
section "8. Retire config/camera.env"
if [[ -f "${CAMERA_ENV}" ]]; then
    info "removing ${CAMERA_ENV} (shred -u, best effort: no guarantee on a journaling flash filesystem — inferred)"
    shred -u "${CAMERA_ENV}" 2>/dev/null || rm -f "${CAMERA_ENV}"
fi
[[ ! -e "${CAMERA_ENV}" ]] || err "${CAMERA_ENV} still exists"
ok "config/camera.env is gone"
info "restarting ${WEBUI_SVC} once more so the measurement below is of a WebUI that never had camera.env"
sudocmd systemctl restart "${WEBUI_SVC}"
for _ in $(seq 1 40); do curl -sk -o /dev/null --max-time 3 "https://127.0.0.1:8443/health" && break; sleep 1; done
sleep 15
section "9. P5 — WebUI frame rate AFTER"
FPS_AFTER="$(measure_fps 30)"
ok "WebUI frame_count rate AFTER: ${FPS_AFTER% *} /s (BEFORE ${FPS_BEFORE% *} /s; is_synthetic=${FPS_AFTER#* })"
[[ "${FPS_AFTER#* }" == "False" ]] || err "P5 FAILED: the WebUI is on the SYNTHETIC fallback with the credential route (credential unreadable or camera refuses)"
awk -v a="${FPS_AFTER% *}" 'BEGIN{exit !(a>=12.0)}' || warn "AFTER rate ${FPS_AFTER% *} /s is below 12 /s — compare with BEFORE ${FPS_BEFORE% *} /s before claiming 'no change'"

section "10. P2 — secret scan WITHOUT --known"
MAINPID="$(systemctl show -p MainPID --value trusted-edge)"
set +e
sudocmd env "VAULT_ADDR=${VAULT_ADDR}" "VAULT_CACERT=${INSTALL_DIR}/vault.crt" "VAULT_TOKEN_FILE=${TOKEN_SINK}" PYTHONDONTWRITEBYTECODE=1 \
    "${VENV}/bin/python" "${INSTALL_DIR}/secret_scan.py" \
    --since "${STAGE_START}" --main-pid "${MAINPID}" \
    --dir "${INSTALL_DIR}" --dir /etc --dir /home/jetson --dir /tmp --dir /var/tmp --dir /var/log --dir /root
SCAN_RC=$?
set -e
case ${SCAN_RC} in
    0) ok "P2 verified: zero occurrences (scope: journal since ${STAGE_START} incl. all vault-agent and WebUI logs, every /proc/*/cmdline, trusted-edge environ, files under the listed dirs). The tmpfs source file ${DEST_FILE} and the systemd credential copy under /run are by design NOT scanned." ;;
    1) err "camera credential FOUND (paths above). Not claiming the gate." ;;
    *) err "secret scan could not run or reported only declared hits (rc=${SCAN_RC})" ;;
esac

# ── Summary ───────────────────────────────────────────────────────────────────
section "RESULT (record in CHANGELOG.md, Session 3-5j)"
cat <<EOF
  template       ${AGENT_HCL}: template + template_config (exit_on_retry_failure=false) -> ${DEST_FILE}
  rendered file  ${F_STAT} on tmpfs (dir ${D_STAT}); unreadable for jetson / edge-ingest / nobody
  WebUI          LoadCredential=${CRED_ID} (drop-in ${WEBUI_DROPIN}); delivered credential ${CRED_STAT}
  WebUI fps      before ${FPS_BEFORE% *} /s -> after ${FPS_AFTER% *} /s (is_synthetic=${FPS_AFTER#* })
  P3 exec        first render restarted the WebUI: $(${FILE_PREEXISTED} && echo "n/a (file pre-existed; unchanged render did not restart)" || echo yes)
  P4 restart     file + content survive a vault-agent restart; reboot NOT RUN
  P6 coupling    broken template: vault-agent ${B_ACTIVE}, token valid ${B_TOKEN_OK}, trusted-edge ${B_TE}
  camera.env     removed; secret_scan without --known: zero hits
  NOT RUN        reboot survival; changed-URL propagation; exit_on_retry_failure=true
EOF
ok "Stage 3-5j complete (marker 14_camera_credential is written by setup-jetson.sh)"
