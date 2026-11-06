#!/usr/bin/env bash
# scripts/13-install-trusted-edge.sh
# ──────────────────────────────────────────────────────────────────────────────
# Phase 3 Stage 3-5g (trusted-edge) — marker 13_trusted_edge.
#
# Installs trusted-edge.service: the ONLY host process that touches the camera, the DEK and the
# database.  Routes: GET /frame.jpg, POST /events (everything else 404).
#
# What this script does (every check below runs the real thing; nothing is simulated):
#   0. Entry checks: markers 11_tpm_agent + 12_agent_pipeline, edge token, Vault reachable, user edge-ingest.
#   1. Fix the token directory group (see "Finding" below) so edge-ingest can traverse it, and
#      add a vault-agent drop-in so a restart does not undo it.  Verified as edge-ingest.
#   2. MEASURE the WebUI video frame rate BEFORE (frame_count delta from /api/status).
#   3. Install code + venv + vault.crt into /opt/trusted-edge (outside /home: ProtectHome and
#      /home/jetson = 750 jetson:jetson would otherwise hide them).
#   4. Ingest key: generate ONCE; store SHA-256 in Vault KV edge-ai-demo-kv/edge-device/ingest-key
#      (edge token, create-only cas=0).  The key itself goes to a root-only handoff file for
#      Session 3-5h (gateway provider `edge-ingest`).  It is never printed and never put in a unit file.
#   5. Install the hardened unit, start it, wait for the listener.
#   6. MEASURE CPU / RSS / cgroup memory.peak and the WebUI frame rate AFTER.
#   7. Gate: edge/gate_test.py (401/404/413/429/JPEG/INSERT) and edge/secret_scan.py (no --known since 3-5j).
#   8. MEASURE the source address the OpenShell supervisor companion uses to reach the service
#      (throw-away sandbox, one unauthenticated request to a unique path, read from the service log).
#
# Finding (Session 3-5g, measured): /run/openshell-edge was root:root 2750 although the 3-5f
# docs say root:edge-ingest — user edge-ingest could not enter the directory to read the token.
# 3-5f only tested that `jetson` is blocked, not that edge-ingest can read.
#
# Usage: ./scripts/bootstrap-jetson.sh <jetson-ip> --only-stage 3-5g
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${REPO_DIR}/.setup-state"
MARKER="${STATE_DIR}/13_trusted_edge"
EDGE_SRC="${REPO_DIR}/edge"

INSTALL_DIR="/opt/trusted-edge"
VENV="${INSTALL_DIR}/venv"
UNIT="/etc/systemd/system/trusted-edge.service"
SVC="trusted-edge"
HANDOFF_DIR="/etc/trusted-edge"
HANDOFF_KEY="${HANDOFF_DIR}/ingest-key.handoff"
TOKEN_DIR="/run/openshell-edge"
TOKEN_SINK="${TOKEN_DIR}/vault-token"

if [[ -f "${REPO_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1090,SC1091
  source "${REPO_DIR}/.env"
  set +a
fi

TE_PORT="${TRUSTED_EDGE_PORT:-${TE_PORT:-8095}}"
JETSON_HOSTNAME="${JETSON_HOSTNAME:-jetson.localdomain}"
WEBUI_PORT="${WEBUI_PORT:-8443}"
# First estimate; replaced by the measured memory.peak result (printed in step 6).
TE_MEMORY_MAX="${TE_MEMORY_MAX:-400M}"
WEBUI_STATUS="https://127.0.0.1:${WEBUI_PORT}/api/status"
SB_NAME="te-src-probe"
AGENT_IMAGE="edge-agent-sandbox:dev"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}  ▷ $*${NC}"; }
ok()      { echo -e "${GREEN}  ✓ $*${NC}"; }
warn()    { echo -e "${YELLOW}  ⚠ $*${NC}"; }
err()     { echo -e "${RED}  ✗ $*${NC}"; exit 1; }
section() { echo -e "\n${GREEN}══ $* ══${NC}"; }

sudocmd() { echo "${SUDO_PASS}" | sudo -S "$@"; }

STAGE_START="$(date '+%Y-%m-%d %H:%M:%S')"
KEY_CREATED_THIS_RUN=false
PROBE_SPEC=""
cleanup() {
    [[ -n "${PROBE_SPEC}" ]] && rm -f "${PROBE_SPEC}"
    openshell sandbox delete "${SB_NAME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [[ -f "${MARKER}" ]]; then
    echo -e "${GREEN}Stage 3-5g already complete (marker exists). Skipping.${NC}"
    exit 0
fi
mkdir -p "${STATE_DIR}"

# ── 0. Entry checks ───────────────────────────────────────────────────────────
section "0. Entry checks"
[[ -f "${STATE_DIR}/11_tpm_agent" ]]      || err "Stage 5-1 (11_tpm_agent) not complete."
[[ -f "${STATE_DIR}/12_agent_pipeline" ]] || err "Stage 5-2 (12_agent_pipeline) not complete."
ok "markers 11_tpm_agent and 12_agent_pipeline present"
: "${VAULT_ADDR:?VAULT_ADDR must be set (bootstrap)}"
: "${VAULT_CACERT:?VAULT_CACERT must be set (bootstrap)}"
[[ -f "${VAULT_CACERT}" ]] || err "VAULT_CACERT file not found: ${VAULT_CACERT}"
for f in trusted_edge.py ingest_key_init.py secret_scan.py gate_test.py requirements.txt; do
    [[ -f "${EDGE_SRC}/${f}" ]] || err "missing ${EDGE_SRC}/${f}"
done
id edge-ingest >/dev/null 2>&1 || err "user edge-ingest does not exist (created by stage 5-1)"
ok "user edge-ingest: $(id edge-ingest)"
systemctl is-active --quiet vault-agent || err "vault-agent.service is not active"
sudocmd test -s "${TOKEN_SINK}" || err "edge token missing at ${TOKEN_SINK}"
ok "vault-agent active, edge token present"
curl -s --cacert "${VAULT_CACERT}" --max-time 5 "${VAULT_ADDR}/v1/sys/health" \
    | python3 -c "import json,sys; sys.exit(0 if not json.load(sys.stdin).get('sealed') else 1)" \
    || err "Vault at ${VAULT_ADDR} not reachable or sealed"
ok "Vault reachable and unsealed (${VAULT_ADDR})"

LAN_IP="$(ip -4 route get "$(echo "${VAULT_ADDR}" | sed -E 's#https?://([^:/]+).*#\1#')" | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
[[ -n "${LAN_IP}" ]] || err "cannot determine the LAN address used to reach Vault"
ok "LAN bind address: ${LAN_IP} (policy never authorizes loopback — AGENTS.md §3)"
if sudocmd ss -ltnH "sport = :${TE_PORT}" | grep -q . && ! systemctl is-active --quiet "${SVC}"; then
    err "port ${TE_PORT} is already in use by something else"
fi

# ── 1. Token directory group ──────────────────────────────────────────────────
section "1. Token directory readable by edge-ingest"
info "before: $(sudocmd stat -c '%a %U:%G' "${TOKEN_DIR}") ${TOKEN_DIR}; $(sudocmd stat -c '%a %U:%G' "${TOKEN_SINK}") token file"
AGENT_HCL="/etc/vault-agent/vault-agent.hcl"
EDGE_GID="$(getent group edge-ingest | cut -d: -f3)"
[[ -n "${EDGE_GID}" ]] || err "cannot resolve the gid of group edge-ingest"

# Measured (3-5g run 2): `vault agent` logs "file sink configured: ... owner=0 group=0" and rewrites
# the token file with that group on every (re)start, so chgrp/setgid cannot hold.  Documented fix:
# the file sink has `owner` (uid) and `group` (gid) settings
# (https://developer.hashicorp.com/vault/docs/agent-and-proxy/autoauth/sinks/file).
info "vault-agent sink config: setting group = ${EDGE_GID} (edge-ingest), owner = 0"
if sudocmd grep -Eq '^[[:space:]]*group[[:space:]]*=' "${AGENT_HCL}"; then
    info "${AGENT_HCL} already has a sink group setting — leaving it"
else
    [[ "$(sudocmd grep -Ec '^[[:space:]]*mode[[:space:]]*=[[:space:]]*0640[[:space:]]*$' "${AGENT_HCL}")" == "1" ]] \
        || err "${AGENT_HCL}: expected exactly one 'mode = 0640' line in the sink block — not editing it blind"
    sudocmd cp -p "${AGENT_HCL}" "${AGENT_HCL}.pre-3-5g"
    sudocmd sed -i -E "/^[[:space:]]*mode[[:space:]]*=[[:space:]]*0640[[:space:]]*$/a\\      owner = 0\\n      group = ${EDGE_GID}" "${AGENT_HCL}"
    sudocmd grep -Eq "^[[:space:]]*group[[:space:]]*=[[:space:]]*${EDGE_GID}[[:space:]]*$" "${AGENT_HCL}" \
        || { sudocmd cp -p "${AGENT_HCL}.pre-3-5g" "${AGENT_HCL}"; err "edit of ${AGENT_HCL} did not apply — restored the backup"; }
    ok "sink block now: $(sudocmd sed -n '/sink "file"/,/^  }/p' "${AGENT_HCL}" | tr -s ' \n' ' ')"
fi

# Directory (measured, runs 2-4): chgrp/chmod of /run/openshell-edge in ExecStartPre AND in a
# straight ExecStartPost both exited 0 yet the directory was root:root afterwards; only a chgrp that
# waited for the token file held (run 2).  What resets it is NOT identified.  So the design no longer
# depends on the directory group: RuntimeDirectoryMode= is applied by systemd on every start
# (https://man7.org/linux/man-pages/man5/systemd.exec.5.html) and is set to 0755.  The secret is the
# FILE: 0640 root:edge-ingest (sink group setting, measured).  Trade-off: every local user can see that
# the file exists; none but root and edge-ingest can read it.
DROPIN_DIR="/etc/systemd/system/vault-agent.service.d"
sudocmd install -d -m 0755 "${DROPIN_DIR}"
DROPIN_TMP="$(mktemp)"
cat > "${DROPIN_TMP}" <<'EOF'
# Session 3-5g: trusted-edge (User=edge-ingest) must traverse /run/openshell-edge.
# The token FILE group comes from the sink setting `group` in /etc/vault-agent/vault-agent.hcl.
[Service]
RuntimeDirectoryMode=0755
EOF
sudocmd install -m 0644 -o root -g root "${DROPIN_TMP}" "${DROPIN_DIR}/10-sinkdir-group.conf"
rm -f "${DROPIN_TMP}"
sudocmd systemctl daemon-reload

sudocmd chmod 0755 "${TOKEN_DIR}"
info "restarting vault-agent (TPM re-auth, ~seconds) and checking the result it actually produces"
RESTART_AT="$(date '+%Y-%m-%d %H:%M:%S')"
sudocmd systemctl restart vault-agent
for _ in $(seq 1 30); do sudocmd test -s "${TOKEN_SINK}" && break; sleep 1; done
if ! sudocmd test -s "${TOKEN_SINK}"; then
    if [[ -f "${AGENT_HCL}.pre-3-5g" ]]; then
        warn "no token after restart — restoring the previous agent config"
        sudocmd cp -p "${AGENT_HCL}.pre-3-5g" "${AGENT_HCL}"; sudocmd systemctl restart vault-agent || true
    fi
    sudocmd journalctl -u vault-agent --since "${RESTART_AT}" --no-pager -o cat | tail -15 | sed 's/^/    | /'
    err "edge token did not reappear after vault-agent restart"
fi
sleep 2
sudocmd journalctl -u vault-agent --since "${RESTART_AT}" --no-pager -o cat | grep "file sink configured" | sed 's/^/    | /'
DIR_AFTER="$(sudocmd stat -c '%a %U:%G' "${TOKEN_DIR}")"
FILE_AFTER="$(sudocmd stat -c '%a %U:%G' "${TOKEN_SINK}")"
info "after restart: dir ${DIR_AFTER}, token ${FILE_AFTER}"
# Session 7-2d: the directory group is not part of the protection. Stage 5-1 writes vault-agent.service with
# Group=edge-ingest, and systemd gives a RuntimeDirectory the unit's User=/Group= (systemd.exec(5)), so the
# directory is 'root:edge-ingest' on a freshly installed device (seen 2026-11-03); the 3-5g device showed
# 'root:root'. With mode 755 the group's r-x equals 'other' r-x, so both mean the same access. What must hold:
# mode 755 (edge-ingest can traverse), owner root (nobody else controls the directory), token file 640 below.
[[ "${DIR_AFTER%% *}" == "755" ]] || err "after restart the token dir mode is '${DIR_AFTER%% *}', expected 755 (dir ${DIR_AFTER})"
[[ "${DIR_AFTER#* }" == root:* ]] || err "after restart the token dir is owned by '${DIR_AFTER#* }', expected owner root (dir ${DIR_AFTER})"
[[ "${FILE_AFTER}" == "640 root:edge-ingest" ]] || err "after restart the token file is '${FILE_AFTER}', expected '640 root:edge-ingest'"
sudocmd -u edge-ingest test -r "${TOKEN_SINK}" || err "edge-ingest cannot read the token after restart"
if sudocmd -u jetson test -r "${TOKEN_SINK}" 2>/dev/null; then err "user jetson can read the edge token — permissions too open"; fi
ok "verified after a real vault-agent restart: edge-ingest can read the token, jetson cannot"
info "NOT verified here: a boot (RuntimeDirectory recreated) and an hourly token renewal — re-check the token file a few hours later"

# ── 2. WebUI frame rate BEFORE ───────────────────────────────────────────────
section "2. WebUI video frame rate BEFORE"
if systemctl is-active --quiet "${SVC}"; then
    info "${SVC} already running (re-run) — stopping it for a clean 'before'"
    sudocmd systemctl stop "${SVC}"
fi
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
systemctl is-active --quiet live-vlm-webui || err "live-vlm-webui is not active — nothing to compare against"
FPS_BEFORE="$(measure_fps 30)"
ok "WebUI frame_count rate BEFORE: ${FPS_BEFORE% *} /s over 30 s (is_synthetic=${FPS_BEFORE#* })"
[[ "${FPS_BEFORE#* }" == "False" ]] || warn "WebUI is on the SYNTHETIC fallback — the before/after comparison is not about the real camera"

# ── 3. Install code, venv, CA ────────────────────────────────────────────────
section "3. Install to ${INSTALL_DIR}"
sudocmd install -d -m 0755 -o root -g root "${INSTALL_DIR}"
for f in trusted_edge.py ingest_key_init.py secret_scan.py gate_test.py requirements.txt; do
    sudocmd install -m 0644 -o root -g root "${EDGE_SRC}/${f}" "${INSTALL_DIR}/${f}"
done
sudocmd install -m 0644 -o root -g root "${VAULT_CACERT}" "${INSTALL_DIR}/vault.crt"
if [[ ! -x "${VENV}/bin/python" ]]; then
    info "creating venv ${VENV}"
    sudocmd python3 -m venv "${VENV}"
fi
sudocmd "${VENV}/bin/python" -m pip install --quiet --upgrade pip
sudocmd "${VENV}/bin/python" -m pip install --quiet -r "${INSTALL_DIR}/requirements.txt"
"${VENV}/bin/python" -c "import cv2, requests, psycopg2, cryptography; print('  cv2', cv2.__version__, '| requests', requests.__version__, '| psycopg2', psycopg2.__version__, '| cryptography', cryptography.__version__)" \
    || err "import check of the venv failed"
(cd "${INSTALL_DIR}" && sudocmd -u edge-ingest env PYTHONDONTWRITEBYTECODE=1 "${VENV}/bin/python" -c "import trusted_edge") \
    || err "user edge-ingest cannot import trusted_edge from ${INSTALL_DIR}"
ok "installed; edge-ingest can import trusted_edge"

# ── 4. Ingest key ────────────────────────────────────────────────────────────
section "4. Ingest key (hash -> Vault KV, key -> root-only handoff for 3-5h)"
sudocmd install -d -m 0700 -o root -g root "${HANDOFF_DIR}"
if ! sudocmd test -s "${HANDOFF_KEY}"; then
    # umask 077 inside a root shell: file is created 0600 root:root, never printed.
    sudocmd bash -c "umask 077; openssl rand -hex 32 > '${HANDOFF_KEY}'"
    KEY_CREATED_THIS_RUN=true
    info "generated a new ingest key (not shown)"
else
    info "reusing the ingest key from the earlier run (not shown)"
fi
sudocmd chown root:root "${HANDOFF_KEY}"; sudocmd chmod 0600 "${HANDOFF_KEY}"
KEY_HASH="$(sudocmd cat "${HANDOFF_KEY}" | tr -d '\n' | sha256sum | awk '{print $1}')"
EDGE_ENV=(env "VAULT_ADDR=${VAULT_ADDR}" "VAULT_CACERT=${INSTALL_DIR}/vault.crt" PYTHONDONTWRITEBYTECODE=1)
INIT_RESULT="$(cd "${INSTALL_DIR}" && sudocmd -u edge-ingest "${EDGE_ENV[@]}" "${VENV}/bin/python" "${INSTALL_DIR}/ingest_key_init.py" "${KEY_HASH}")" \
    || { ${KEY_CREATED_THIS_RUN} && sudocmd rm -f "${HANDOFF_KEY}"; err "ingest_key_init.py failed (see message above)"; }
case "${INIT_RESULT}" in
    CREATED)        ok "SHA-256 of the ingest key stored in Vault KV edge-ai-demo-kv/edge-device/ingest-key (create-only)" ;;
    EXISTS_SAME)    ok "Vault already holds the SHA-256 of this key (re-run)" ;;
    EXISTS_DIFFERENT)
        ${KEY_CREATED_THIS_RUN} && sudocmd rm -f "${HANDOFF_KEY}"
        err "Vault holds a DIFFERENT ingest-key hash and the edge policy is create-only (cannot overwrite). Rotate on the Mac: vault kv metadata delete -mount=edge-ai-demo-kv edge-device/ingest-key ; then re-run this stage." ;;
    *) err "unexpected ingest_key_init.py result: '${INIT_RESULT}'" ;;
esac

# ── 5. systemd unit ──────────────────────────────────────────────────────────
section "5. Hardened unit ${SVC}.service"
UNIT_TMP="$(mktemp)"
cat > "${UNIT_TMP}" <<EOF
[Unit]
Description=trusted-edge: camera, DEK and database holder (Session 3-5g)
After=network-online.target vault-agent.service
Wants=network-online.target vault-agent.service

[Service]
Type=simple
User=edge-ingest
Group=edge-ingest
WorkingDirectory=${INSTALL_DIR}
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONDONTWRITEBYTECODE=1
Environment=TE_BIND=${LAN_IP}
Environment=TE_PORT=${TE_PORT}
Environment=VAULT_ADDR=${VAULT_ADDR}
Environment=VAULT_CACERT=${INSTALL_DIR}/vault.crt
ExecStart=${VENV}/bin/python ${INSTALL_DIR}/trusted_edge.py
Restart=on-failure
RestartSec=5s
# exit 3 = camera URL in Vault is still the init-vault.sh placeholder: do not loop.
RestartPreventExitStatus=3
TimeoutStopSec=15
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SVC}

# ── hardening ──
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ProtectProc=invisible
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
SystemCallArchitectures=native
CapabilityBoundingSet=
AmbientCapabilities=
UMask=0077
# No ReadWritePaths= : the service writes nothing to disk (PrivateTmp only).
MemoryMax=${TE_MEMORY_MAX}
MemorySwapMax=0

[Install]
WantedBy=multi-user.target
EOF
sudocmd install -m 0644 -o root -g root "${UNIT_TMP}" "${UNIT}"
rm -f "${UNIT_TMP}"
sudocmd systemctl daemon-reload
sudocmd systemctl enable "${SVC}.service" >/dev/null 2>&1
SVC_START="$(date '+%Y-%m-%d %H:%M:%S')"
sudocmd systemctl restart "${SVC}.service"
info "waiting for ${LAN_IP}:${TE_PORT} (max 60 s)"
UP=false
for _ in $(seq 1 60); do
    if ! systemctl is-active --quiet "${SVC}"; then break; fi
    if sudocmd ss -ltnH "sport = :${TE_PORT}" | grep -q "${LAN_IP}:${TE_PORT}"; then UP=true; break; fi
    sleep 1
done
if ! ${UP}; then
    warn "service did not reach listening state — journal:"
    sudocmd journalctl -u "${SVC}" --since "${SVC_START}" --no-pager | tail -25 | sed 's/^/    | /'
    err "${SVC} failed to start"
fi
ok "${SVC} listening on ${LAN_IP}:${TE_PORT}"
MAINPID="$(systemctl show -p MainPID --value "${SVC}")"
sudocmd journalctl -u "${SVC}" --since "${SVC_START}" --no-pager -o cat | grep -E "camera URL present|bind=|RTSP connected|starting" | sed 's/^/    | /'

# ── 6. Measurements ──────────────────────────────────────────────────────────
section "6. Measurements (service + camera reader running, WebUI streaming)"
info "warming up 70 s so the reader logs one stats window"
sleep 70
CLK="$(getconf CLK_TCK)"
cpu_ticks() { awk '{print $14+$15}' "/proc/${MAINPID}/stat"; }
T0=$(cpu_ticks); W0=$(date +%s.%N)
FPS_AFTER="$(measure_fps 30)"
T1=$(cpu_ticks); W1=$(date +%s.%N)
SVC_CPU="$(awk -v a="$T0" -v b="$T1" -v c="$CLK" -v w0="$W0" -v w1="$W1" 'BEGIN{printf "%.1f", 100*((b-a)/c)/(w1-w0)}')"
RSS_MB="$(awk '/VmRSS/{printf "%.0f", $2/1024}' "/proc/${MAINPID}/status")"
CG="/sys/fs/cgroup/system.slice/${SVC}.service"
MEM_CUR="$(awk '{printf "%.0f", $1/1048576}' "${CG}/memory.current" 2>/dev/null || echo "?")"
MEM_PEAK="$(awk '{printf "%.0f", $1/1048576}' "${CG}/memory.peak" 2>/dev/null || echo "?")"
ok "trusted-edge CPU (30 s window, whole process): ${SVC_CPU}% of one core"
ok "trusted-edge VmRSS: ${RSS_MB} MB | cgroup memory.current ${MEM_CUR} MB, memory.peak ${MEM_PEAK} MB (MemoryMax=${TE_MEMORY_MAX})"
ok "WebUI frame_count rate AFTER:  ${FPS_AFTER% *} /s (BEFORE ${FPS_BEFORE% *} /s; is_synthetic=${FPS_AFTER#* })"
[[ "${FPS_AFTER#* }" == "False" ]] || warn "WebUI is on the SYNTHETIC fallback AFTER trusted-edge connected — the camera may refuse a 2nd RTSP session; this is a FINDING, do not ignore it"
echo "    reader thread stats from the service log:"
sudocmd journalctl -u "${SVC}" --since "${SVC_START}" --no-pager -o cat | grep "reader stats" | tail -3 | sed 's/^/    | /'
free -m | awk 'NR<=2{print "    | "$0}'

# ── 7. Gate ──────────────────────────────────────────────────────────────────
section "7a. Gate: HTTP behaviour against the real service"
GATE_OUT="$(mktemp)"
set +e
sudocmd cat "${HANDOFF_KEY}" | python3 "${EDGE_SRC}/gate_test.py" "${LAN_IP}" "${TE_PORT}" | tee "${GATE_OUT}"
GATE_RC=${PIPESTATUS[1]}
set -e
ROW_ID="$(sed -n 's/^  ROW_ID=//p' "${GATE_OUT}" | head -1)"
rm -f "${GATE_OUT}"
[[ ${GATE_RC} -eq 0 ]] || err "gate_test.py failed — see lines above"
ok "HTTP gate passed; test row id=${ROW_ID:-NOT REPORTED by gate_test.py} (verify ciphertext on the Mac)"
sudocmd journalctl -u "${SVC}" --since "${SVC_START}" --no-pager -o cat | grep -E "event stored|DB insert failed" | tail -3 | sed 's/^/    | /'
MEM_PEAK2="$(awk '{printf "%.0f", $1/1048576}' "${CG}/memory.peak" 2>/dev/null || echo "?")"
ok "cgroup memory.peak after the gate traffic: ${MEM_PEAK2} MB"

section "7b. Gate: camera credential must not appear anywhere it should not"
# The scanner prints counts and paths only; the needles are derived in memory from Vault.
# config/camera.env is a declared known-hit until stage 3-5j (camera-credential) retires it.
# Once 3-5j has run (marker 14_camera_credential present) the --known flag is omitted and any
# hit causes a hard failure.
SCAN_KNOWN_ARGS=()
if [[ ! -f "${STATE_DIR}/14_camera_credential" ]]; then
    SCAN_KNOWN_ARGS=(--known "${REPO_DIR}/config/camera.env")
    info "stage 3-5j not yet run: config/camera.env declared as known-hit (THREAT_MODEL T-13)"
fi
set +e
sudocmd env "VAULT_ADDR=${VAULT_ADDR}" "VAULT_CACERT=${INSTALL_DIR}/vault.crt" "VAULT_TOKEN_FILE=${TOKEN_SINK}" PYTHONDONTWRITEBYTECODE=1 \
    "${VENV}/bin/python" "${INSTALL_DIR}/secret_scan.py" \
    --since "${STAGE_START}" --main-pid "${MAINPID}" \
    --dir "${INSTALL_DIR}" --dir /etc --dir "${REPO_DIR}" --dir /tmp --dir /var/tmp --dir /var/log --dir /root \
    "${SCAN_KNOWN_ARGS[@]}"
SCAN_RC=$?
set -e
case ${SCAN_RC} in
    0) ok "no unexpected occurrence of the RTSP URL or its password (journal, process args, environ, unit files, scanned dirs)" ;;
    1) err "camera credential FOUND in an unexpected location (paths above)" ;;
    2) err "secret scan could not run (rc=2)" ;;
    3) ok "camera credential found only in the declared known location (config/camera.env — retire with stage 3-5j)" ;;
    *) err "secret scan could not run (rc=${SCAN_RC})" ;;
esac
sudocmd systemctl cat "${SVC}" | grep -q "rtsp://" && err "unit file contains rtsp://" || ok "unit file contains no rtsp://"

# ── 8. Supervisor companion source address ───────────────────────────────────
section "8. Source address the OpenShell supervisor companion uses to reach ${LAN_IP}:${TE_PORT}"
# The probe sandbox is created from the agent image, which stage 3-5i normally builds later. Build it here
# if it is missing (same Dockerfile and command as 3-5i), so a fresh device does not skip this measurement
# for lack of an image (Session 7-2d).
if ! docker image inspect "${AGENT_IMAGE}" >/dev/null 2>&1; then
    info "image ${AGENT_IMAGE} not present yet — building it from agent/Dockerfile (stage 3-5i rebuilds it later)"
    docker build --quiet -t "${AGENT_IMAGE}" -f "${REPO_DIR}/agent/Dockerfile" "${REPO_DIR}/agent/" >/dev/null \
        || warn "could not build ${AGENT_IMAGE} — the probe sandbox below will fail and the source address is NOT measured"
fi
PROBE_SPEC="$(mktemp)"
{ awk '/^network_policies:/{exit} {print}' "${REPO_DIR}/agent/policy.yaml"
  cat <<EOF
network_policies:
  trusted-edge-probe:
    endpoints:
      - host: ${JETSON_HOSTNAME}
        port: ${TE_PORT}
    binaries:
      - path: /usr/bin/python3.12
EOF
} > "${PROBE_SPEC}"
PROBE_PATH="/probe-sandbox-$(openssl rand -hex 4)"
SRC_ADDR=""
openshell sandbox delete "${SB_NAME}" >/dev/null 2>&1 || true
if timeout 240 openshell sandbox create --name "${SB_NAME}" --no-tty --detach --no-auto-providers \
        --from "${AGENT_IMAGE}" --policy "${PROBE_SPEC}" -- sleep 300 >/tmp/te-src-probe.create 2>&1; then
    for _ in $(seq 1 30); do
        [[ "$(openshell sandbox list 2>&1 | awk -v n="${SB_NAME}" '$1==n {print $NF}')" == "Ready" ]] && break
        sleep 2
    done
    PY='import sys,urllib.request
try:
    urllib.request.urlopen(sys.argv[1], timeout=15)
except Exception as e:
    print("HTTP", getattr(e, "code", type(e).__name__))'
    openshell sandbox exec -n "${SB_NAME}" --no-tty --no-login-shell --timeout 60 -- \
        /usr/bin/python3.12 -c "${PY}" "http://${JETSON_HOSTNAME}:${TE_PORT}${PROBE_PATH}" 2>&1 | sed 's/^/    sandbox says: /'
    sleep 1
    LINE="$(sudocmd journalctl -u "${SVC}" --since "${STAGE_START}" --no-pager -o cat | grep "${PROBE_PATH}" | tail -1 || true)"
    if [[ -n "${LINE}" ]]; then
        SRC_ADDR="$(sed -n 's/.*req client=\([0-9.]*\):.*/\1/p' <<<"${LINE}")"
        ok "service log line for the sandbox request: ${LINE}"
        ok "SOURCE ADDRESS seen by trusted-edge: ${SRC_ADDR}"
    else
        warn "the sandbox request never reached the service (blocked by policy or DNS?) — source address NOT measured"
        tail -5 /tmp/te-src-probe.create | sed 's/^/    | /'
    fi
else
    warn "could not create the probe sandbox — source address NOT measured:"
    tail -8 /tmp/te-src-probe.create | sed 's/^/    | /'
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
systemd-analyze security "${SVC}" --no-pager 2>/dev/null | tail -1 | sed 's/^/    systemd-analyze security: /' || true
section "RESULT (record in CHANGELOG.md, Session 3-5g)"
cat <<EOF
  service        ${SVC}.service  User=edge-ingest  ${LAN_IP}:${TE_PORT}  MemoryMax=${TE_MEMORY_MAX}
  token file     ${TOKEN_SINK} (dir $(sudocmd stat -c '%a %U:%G' "${TOKEN_DIR}"), file $(sudocmd stat -c '%a %U:%G' "${TOKEN_SINK}"))
  CPU / RSS      ${SVC_CPU}% of one core / ${RSS_MB} MB   (cgroup memory.peak ${MEM_PEAK2} MB)
  WebUI fps      before ${FPS_BEFORE% *} /s -> after ${FPS_AFTER% *} /s
  supervisor src ${SRC_ADDR:-NOT MEASURED}
  test row id    ${ROW_ID:-NOT REPORTED}
  ingest key     SHA-256 in Vault KV edge-ai-demo-kv/edge-device/ingest-key (create-only);
                 key in ${HANDOFF_KEY} (root 0600) until Session 3-5h creates provider 'edge-ingest'
EOF
ok "Stage 3-5g complete (marker 13_trusted_edge is written by setup-jetson.sh)"
