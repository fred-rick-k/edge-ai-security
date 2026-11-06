#!/usr/bin/env bash
# scripts/21-vault-widgets.sh
# ──────────────────────────────────────────────────────────────────────────────
# Phase 5 Session 5-3b (vault-widgets) — marker 15_vault_widgets.
#
# Deploys the three Vault-backed Tab-1 widgets and MEASURES them:
#   1. Hardware-Rooted Identity strip   GET  /api/vault/identity
#   2. Vault Dynamic Credentials tile   GET  /api/vault/db-credential , POST /api/vault/rotate-credential
#   3. Payload Privacy Toggle           GET  /api/vault/events , POST /api/vault/decrypt
#
# What this stage does (all idempotent; NEVER re-runs stage 3-5g, which would rotate the ingest key, T-27):
#   a. installs the updated trusted_edge.py + admin_key_init.py into /opt/trusted-edge
#      and `pip install -r ui/requirements.txt` (adds `cryptography`) into ui/.venv
#   b. creates a SEPARATE admin key (/etc/webui-vault/admin-key, root 0600), stores only its SHA-256 in
#      Vault KV edge-ai-demo-kv/edge-device/admin-key (create-only, via the edge token, as user edge-ingest)
#   c. installs the control-plane-reader AppRole role_id + secret_id (pushed by bootstrap-jetson.sh from the
#      Mac server; the ROOT TOKEN is never read or sent) to /etc/webui-vault/control-reader (root 0600)
#   d. restarts trusted-edge, writes a WebUI drop-in with LoadCredential= for both files, restarts the WebUI
#   e. measures: key separation, identity (real lookup-self), credential status, Rotate (usernames, rows),
#      decrypt of a real stored row + two negative tests, secret scan for the admin key and secret_id
#
# Documentation read before writing this (AGENTS.md 0.1 rule 6):
#   Vault lease revoke   https://developer.hashicorp.com/vault/api-docs/system/leases#revoke-lease
#   Vault AppRole login  https://developer.hashicorp.com/vault/api-docs/auth/approle#login-with-approle
#   Vault Transit decrypt https://developer.hashicorp.com/vault/api-docs/secret/transit#decrypt-data
#   Vault token lookup-self https://developer.hashicorp.com/vault/api-docs/auth/token#lookup-a-token-self
#   systemd.exec(5) LoadCredential= (same mechanism as stage 3-5j)
#
# Not provable from the Jetson (done on the Mac afterwards, see CHANGELOG): that the OLD lease is gone in Vault
# (`vault lease lookup`) and that the old PostgreSQL role was dropped (pg_roles).  This stage prints both ids.
#
# Usage: ./scripts/bootstrap-jetson.sh <jetson-ip> --only-stage 5-3b
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${REPO_DIR}/.setup-state"
MARKER="${STATE_DIR}/15_vault_widgets"
EDGE_SRC="${REPO_DIR}/edge"
UI_DIR="${REPO_DIR}/ui"

if [[ -f "${REPO_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1090,SC1091
  source "${REPO_DIR}/.env"
  set +a
fi

INSTALL_DIR="/opt/trusted-edge"
VENV="${INSTALL_DIR}/venv"
SVC="trusted-edge"
TE_PORT="${TRUSTED_EDGE_PORT:-${TE_PORT:-8095}}"
CRED_DIR_SRC="/etc/webui-vault"
ADMIN_KEY_FILE="${CRED_DIR_SRC}/admin-key"
CONTROL_FILE="${CRED_DIR_SRC}/control-reader"
MAC_KEY_DEST="${CRED_DIR_SRC}/mac-key"
WEBUI_SVC="live-vlm-webui"
WEBUI_DROPIN_DIR="/etc/systemd/system/${WEBUI_SVC}.service.d"
WEBUI_DROPIN="${WEBUI_DROPIN_DIR}/20-vault-widgets.conf"
WEBUI_PORT="${WEBUI_PORT:-8443}"
WEBUI="https://127.0.0.1:${WEBUI_PORT}"
GATEWAY_TOKEN="/run/openshell/vault-token"
EDGE_TOKEN="/run/openshell-edge/vault-token"
ROWS_WAIT_SEC="${ROWS_WAIT_SEC:-180}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}  ▷ $*${NC}"; }
ok()      { echo -e "${GREEN}  ✓ $*${NC}"; }
warn()    { echo -e "${YELLOW}  ⚠ $*${NC}"; }
err()     { echo -e "${RED}  ✗ $*${NC}"; exit 1; }
section() { echo -e "\n${GREEN}══ $* ══${NC}"; }
sudocmd() { echo "${SUDO_PASS}" | sudo -S "$@"; }

STAGE_START="$(date '+%Y-%m-%d %H:%M:%S')"
ADMIN_KEY=""
cleanup() {
    ADMIN_KEY=""
    # The handoff files from bootstrap hold credentials: remove them whatever happens.
    [[ -n "${CONTROL_READER_FILE:-}" ]] && rm -f "${CONTROL_READER_FILE}" 2>/dev/null || true
    [[ -n "${MAC_KEY_FILE:-}" ]] && rm -f "${MAC_KEY_FILE}" 2>/dev/null || true
}
trap cleanup EXIT

if [[ -f "${MARKER}" ]]; then
    echo -e "${GREEN}Stage 5-3b already complete (marker exists). Skipping.${NC}"
    exit 0
fi
mkdir -p "${STATE_DIR}"

# ── 0. Entry checks ───────────────────────────────────────────────────────────
section "0. Entry checks"
for m in 11_tpm_agent 11b_tpm_gateway_agent 13_trusted_edge 14_camera_credential 09_webui; do
    [[ -f "${STATE_DIR}/${m}" ]] || err "marker ${m} missing — earlier stage not complete"
done
ok "markers 11_tpm_agent 11b_tpm_gateway_agent 13_trusted_edge 14_camera_credential 09_webui present"
: "${VAULT_ADDR:?VAULT_ADDR must be set (bootstrap)}"
: "${VAULT_CACERT:?VAULT_CACERT must be set (bootstrap)}"
[[ -f "${VAULT_CACERT}" ]] || err "VAULT_CACERT file not found: ${VAULT_CACERT}"
for f in trusted_edge.py admin_key_init.py; do [[ -f "${EDGE_SRC}/${f}" ]] || err "missing ${EDGE_SRC}/${f}"; done
grep -q "handle_vault_decrypt" "${UI_DIR}/server.py" || err "ui/server.py on this device has no /api/vault endpoints (rsync of the new code missing?)"
for s in "${SVC}" vault-agent vault-agent-gateway "${WEBUI_SVC}"; do
    if ! systemctl is-active --quiet "${s}"; then
        if [[ "${s}" == "${SVC}" ]]; then
            info "trusted-edge is inactive; attempting to start it with sudocmd..."
            sudocmd systemctl start "${SVC}" || err "Failed to start ${SVC}"
        else
            err "${s}.service is not active"
        fi
    fi
done
sudocmd test -s "${EDGE_TOKEN}"    || err "edge token missing at ${EDGE_TOKEN}"
sudocmd test -s "${GATEWAY_TOKEN}" || err "gateway token missing at ${GATEWAY_TOKEN}"
id edge-ingest >/dev/null 2>&1     || err "user edge-ingest does not exist"
ok "trusted-edge, vault-agent, vault-agent-gateway, ${WEBUI_SVC} active; both token sinks present"
LAN_IP="$(ip -4 route get "$(echo "${VAULT_ADDR}" | sed -E 's#https?://([^:/]+).*#\1#')" | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
[[ -n "${LAN_IP}" ]] || err "cannot determine the LAN address used to reach Vault"
ok "trusted-edge address: ${LAN_IP}:${TE_PORT}"

HAVE_CR_FILE=false
if [[ -n "${CONTROL_READER_FILE:-}" && -s "${CONTROL_READER_FILE}" ]]; then
    HAVE_CR_FILE=true
elif sudocmd test -s "${CONTROL_FILE}"; then
    info "no new control-plane-reader handoff; reusing the installed ${CONTROL_FILE}"
else
    err "no control-plane-reader credential: run via ./scripts/bootstrap-jetson.sh <ip> --only-stage 5-3b (it pushes role_id/secret_id from the Mac)"
fi

HAVE_MK_FILE=false
if [[ -n "${MAC_KEY_FILE:-}" && -s "${MAC_KEY_FILE}" ]]; then
    HAVE_MK_FILE=true
elif sudocmd test -s "${MAC_KEY_DEST}"; then
    info "no new Mac SSH key handoff; reusing the installed ${MAC_KEY_DEST}"
else
    err "no Mac SSH private key: run via ./scripts/bootstrap-jetson.sh <ip> --only-stage 5-3b (it pushes the Mac SSH key from the workstation)"
fi

# Clean up any stale staging files in /tmp from previous failed/aborted runs
# to prevent them from triggering false positives in the upcoming secret scan.
info "Cleaning up stale staging files in /tmp..."
for f in /tmp/.cr.* /tmp/.mk.*; do
    if [[ -f "$f" && "$f" != "${CONTROL_READER_FILE:-}" && "$f" != "${MAC_KEY_FILE:-}" ]]; then
        sudocmd rm -f "$f" 2>/dev/null || true
    fi
done
 
# ── 1. Code ───────────────────────────────────────────────────────────────────
section "1. Install updated trusted-edge code; add cryptography to the WebUI venv"
sudocmd install -m 0644 -o root -g root "${EDGE_SRC}/trusted_edge.py"   "${INSTALL_DIR}/trusted_edge.py"
sudocmd install -m 0644 -o root -g root "${EDGE_SRC}/admin_key_init.py" "${INSTALL_DIR}/admin_key_init.py"
(cd "${INSTALL_DIR}" && sudocmd -u edge-ingest env PYTHONDONTWRITEBYTECODE=1 "${VENV}/bin/python" -c "import trusted_edge, admin_key_init") \
    || err "edge-ingest cannot import the updated trusted_edge / admin_key_init"
ok "trusted_edge.py + admin_key_init.py installed in ${INSTALL_DIR}; import check as edge-ingest OK"
[[ -x "${UI_DIR}/.venv/bin/pip" ]] || err "${UI_DIR}/.venv missing (stage 2-1)"
"${UI_DIR}/.venv/bin/pip" install --quiet -r "${UI_DIR}/requirements.txt"
"${UI_DIR}/.venv/bin/python" -c "import cryptography, aiohttp; print('    cryptography', cryptography.__version__)" \
    || err "ui/.venv cannot import cryptography"
ok "ui/.venv: cryptography importable"

# ── 2. Admin key ──────────────────────────────────────────────────────────────
section "2. Admin key (separate from the ingest key)"
sudocmd install -d -m 0700 -o root -g root "${CRED_DIR_SRC}"
if sudocmd test -s "${ADMIN_KEY_FILE}"; then
    info "admin key file exists — reused"
else
    sudocmd bash -c "umask 077; openssl rand -hex 32 > '${ADMIN_KEY_FILE}'"
    sudocmd chown root:root "${ADMIN_KEY_FILE}"; sudocmd chmod 600 "${ADMIN_KEY_FILE}"
    ok "admin key generated (${ADMIN_KEY_FILE}, root 0600; value never printed)"
fi
ADMIN_KEY="$(sudocmd cat "${ADMIN_KEY_FILE}" | tr -d '\n')"
[[ ${#ADMIN_KEY} -eq 64 ]] || err "admin key file has unexpected length"
KEY_HASH="$(printf '%s' "${ADMIN_KEY}" | sha256sum | awk '{print $1}')"
INIT_RESULT="$(cd "${INSTALL_DIR}" && sudocmd -u edge-ingest env "VAULT_ADDR=${VAULT_ADDR}" "VAULT_CACERT=${INSTALL_DIR}/vault.crt" \
    PYTHONDONTWRITEBYTECODE=1 "${VENV}/bin/python" "${INSTALL_DIR}/admin_key_init.py" "${KEY_HASH}")" \
    || err "admin_key_init.py failed (message above)"
case "${INIT_RESULT}" in
    CREATED)        ok "SHA-256 of the admin key stored in Vault KV edge-device/admin-key (create-only)" ;;
    EXISTS_SAME)    ok "Vault already holds the same admin-key hash" ;;
    EXISTS_DIFFERENT) err "Vault holds a DIFFERENT admin-key hash and the edge policy is create-only. On the Mac: vault kv metadata delete -mount=edge-ai-demo-kv edge-device/admin-key ; then re-run this stage." ;;
    *) err "unexpected admin_key_init.py result '${INIT_RESULT}'" ;;
esac

# ── 3. control-plane-reader credential ────────────────────────────────────────
section "3. control-plane-reader AppRole credential"
if ${HAVE_CR_FILE}; then
    python3 - "${CONTROL_READER_FILE}" <<'PY' || err "handoff file is not JSON with role_id and secret_id"
import json, sys
d = json.load(open(sys.argv[1]))
assert set(d) == {"role_id", "secret_id"} and all(isinstance(v, str) and v for v in d.values())
PY
    sudocmd install -m 0600 -o root -g root "${CONTROL_READER_FILE}" "${CONTROL_FILE}"
    rm -f "${CONTROL_READER_FILE}"
    ok "role_id + secret_id installed at ${CONTROL_FILE} (root 0600); handoff file deleted"
fi
[[ "$(sudocmd stat -c '%a %U:%G' "${CONTROL_FILE}")" == "600 root:root" ]] || err "${CONTROL_FILE} is not 0600 root:root"

# ── 3b. Mac SSH private key for Vault audit log ──────────────────────────────────
section "3b. Mac SSH private key for Vault audit log"
if ${HAVE_MK_FILE}; then
    # Verify that the file actually looks like an OpenSSH private key (basic sanity check)
    sudocmd grep -q "PRIVATE KEY" "${MAC_KEY_FILE}" \
        || err "staged Mac SSH private key file is not a valid private key"
    sudocmd install -m 0600 -o root -g root "${MAC_KEY_FILE}" "${MAC_KEY_DEST}"
    rm -f "${MAC_KEY_FILE}"
    ok "Mac SSH private key installed at ${MAC_KEY_DEST} (root 0600); handoff file deleted"
fi
[[ "$(sudocmd stat -c '%a %U:%G' "${MAC_KEY_DEST}")" == "600 root:root" ]] || err "${MAC_KEY_DEST} is not 0600 root:root"
# Prove that the delivered AppRole credential logs in and has only the reader policy (secret never printed).
LOGIN_PY="$(mktemp /tmp/.cr-login.XXXXXX)"
cat > "${LOGIN_PY}" <<'PY'
import json, ssl, sys, urllib.request
f, addr, ca = sys.argv[1:4]
d = json.load(open(f))
req = urllib.request.Request(f"{addr}/v1/auth/approle/login", data=json.dumps(d).encode(), method="POST")
try:
    r = json.load(urllib.request.urlopen(req, context=ssl.create_default_context(cafile=ca), timeout=10))
    print(",".join(r["auth"]["policies"]), r["auth"]["lease_duration"])
except Exception as e:
    print("FAIL", type(e).__name__)
PY
LOGIN_CHECK="$(sudocmd python3 "${LOGIN_PY}" "${CONTROL_FILE}" "${VAULT_ADDR}" "${VAULT_CACERT}")"
rm -f "${LOGIN_PY}"
[[ "${LOGIN_CHECK}" == "edge-ai-demo-policy-control-reader "* ]] \
    || err "AppRole login with the delivered credential failed or has unexpected policies: '${LOGIN_CHECK}'"
ok "delivered credential logs in; token policies = ${LOGIN_CHECK% *}, ttl ${LOGIN_CHECK#* } s"

# ── 3c. trusted-edge database address (Session 7-2b) ──────────────────────────
# Since Session 7-2a edge/trusted_edge.py has no hard-coded Mac address: DB_HOST/DB_PORT/DB_NAME default to
# MAC_IP / POSTGRES_PORT / POSTGRES_DB from the process environment, else to 127.0.0.1 / 5432 / edge_demo.
# scripts/13-install-trusted-edge.sh only sets TE_BIND, TE_PORT, VAULT_ADDR, VAULT_CACERT, so without this
# drop-in the deployed code would try to reach PostgreSQL on 127.0.0.1 of the Jetson.
section "3c. trusted-edge database address drop-in (DB_HOST / DB_PORT / DB_NAME)"
: "${MAC_IP:?MAC_IP must be set in .env}"; : "${POSTGRES_PORT:?POSTGRES_PORT must be set in .env}"; : "${POSTGRES_DB:?POSTGRES_DB must be set in .env}"
TE_DROPIN_DIR="/etc/systemd/system/${SVC}.service.d"
TE_DROPIN="${TE_DROPIN_DIR}/20-db.conf"
TE_DROP_TMP="$(mktemp)"
cat > "${TE_DROP_TMP}" <<EOF
# Session 7-2b: address of the PostgreSQL server on the Mac (no password here; the DB credential is a Vault lease).
[Service]
Environment=DB_HOST=${MAC_IP}
Environment=DB_PORT=${POSTGRES_PORT}
Environment=DB_NAME=${POSTGRES_DB}
EOF
sudocmd install -d -m 0755 "${TE_DROPIN_DIR}"
sudocmd install -m 0644 -o root -g root "${TE_DROP_TMP}" "${TE_DROPIN}"
rm -f "${TE_DROP_TMP}"
ok "${TE_DROPIN}: DB_HOST=${MAC_IP} DB_PORT=${POSTGRES_PORT} DB_NAME=${POSTGRES_DB}"

# ── 4. Restart trusted-edge; WebUI drop-in ────────────────────────────────────
section "4. Restart ${SVC}; WebUI LoadCredential= drop-in"
sudocmd systemctl daemon-reload
RESTART_AT="$(date '+%Y-%m-%d %H:%M:%S')"
sudocmd systemctl restart "${SVC}"
for _ in $(seq 1 60); do
    sudocmd journalctl -u "${SVC}" --since "${RESTART_AT}" --no-pager -o cat | grep -q "listening on" && break; sleep 1
done
systemctl is-active --quiet "${SVC}" || { sudocmd journalctl -u "${SVC}" -n 25 --no-pager -o cat | sed 's/^/    | /'; err "${SVC} not active after restart"; }
sudocmd journalctl -u "${SVC}" --since "${RESTART_AT}" --no-pager -o cat | grep -q "/admin/\* enabled" \
    || { sudocmd journalctl -u "${SVC}" --since "${RESTART_AT}" --no-pager -o cat | tail -15 | sed 's/^/    | /'; err "trusted-edge started with /admin/* disabled"; }
ok "trusted-edge restarted; /admin/* enabled (admin-key hash loaded from Vault)"
# The startup line prints the address the service really uses: assert it is the configured one.
sudocmd journalctl -u "${SVC}" --since "${RESTART_AT}" --no-pager -o cat | grep -F "db=${MAC_IP}:${POSTGRES_PORT}/${POSTGRES_DB}" >/dev/null \
    || { sudocmd journalctl -u "${SVC}" --since "${RESTART_AT}" --no-pager -o cat | grep "bind=" | sed 's/^/    | /'; err "trusted-edge is not using db=${MAC_IP}:${POSTGRES_PORT}/${POSTGRES_DB} (startup line above)"; }
ok "trusted-edge startup line shows db=${MAC_IP}:${POSTGRES_PORT}/${POSTGRES_DB}"

DROP_TMP="$(mktemp)"
cat > "${DROP_TMP}" <<EOF
# Session 5-3b: Vault-backed widgets.  Secrets arrive as systemd credentials (root-only source files);
# the unit's environment carries only addresses and the CA path.
[Service]
LoadCredential=admin-key:${ADMIN_KEY_FILE}
LoadCredential=control-reader:${CONTROL_FILE}
LoadCredential=mac-key:${MAC_KEY_DEST}
Environment=VAULT_ADDR=${VAULT_ADDR}
Environment=VAULT_CACERT=${VAULT_CACERT}
Environment=TRUSTED_EDGE_URL=http://${LAN_IP}:${TE_PORT}
# Session 7-2b: ui/server.py defaults MAC_IP to 127.0.0.1 (7-2a); the audit-log fetch SSHes to MAC_USER@MAC_IP.
Environment=MAC_IP=${MAC_IP}
Environment=MAC_USER=${MAC_USER:-m}
EOF
sudocmd install -d -m 0755 "${WEBUI_DROPIN_DIR}"
sudocmd install -m 0644 -o root -g root "${DROP_TMP}" "${WEBUI_DROPIN}"
rm -f "${DROP_TMP}"
sudocmd systemctl daemon-reload
sudocmd systemctl restart "${WEBUI_SVC}"
for _ in $(seq 1 60); do curl -sk -o /dev/null --max-time 3 "${WEBUI}/health" && break; sleep 1; done
systemctl is-active --quiet "${WEBUI_SVC}" || { sudocmd journalctl -u "${WEBUI_SVC}" -n 25 --no-pager | sed 's/^/    | /'; err "${WEBUI_SVC} not active"; }
WPID="$(systemctl show -p MainPID --value "${WEBUI_SVC}")"
CD="$(tr '\0' '\n' < "/proc/${WPID}/environ" | sed -n 's/^CREDENTIALS_DIRECTORY=//p')"   # WebUI runs as jetson: readable, no sudo (sudo -S would eat the redirected stdin)
[[ -n "${CD}" ]] || err "WebUI has no CREDENTIALS_DIRECTORY"
sudocmd ls -la "${CD}" | sed 's/^/    | /'
for c in admin-key control-reader camera-rtsp-url mac-key; do sudocmd test -s "${CD}/${c}" || err "credential ${c} not delivered to the WebUI"; done
ok "WebUI restarted with credentials admin-key, control-reader, camera-rtsp-url, mac-key"
# daemon-reload resets memory.swap.max of the vlm-server container scope unless systemd's model was updated (T-24).
VCID="$(sudocmd docker inspect -f '{{.Id}}' vlm-server 2>/dev/null || true)"
if [[ -n "${VCID}" ]]; then
    SWAPMAX="$(sudocmd cat "/sys/fs/cgroup/system.slice/docker-${VCID}.scope/memory.swap.max" 2>/dev/null || echo unreadable)"
    [[ "${SWAPMAX}" == "0" ]] && ok "vlm-server memory.swap.max still 0 after daemon-reload" \
        || warn "vlm-server memory.swap.max is '${SWAPMAX}' after daemon-reload (expected 0) — see T-24; re-run scripts/18 probe"
fi

# ── helpers for measurements ──────────────────────────────────────────────────
edge_call() {   # method path -> "<body>\n<code>"; the key travels on stdin (-H @-), never in argv
    printf 'X-Admin-Key: %s\n' "${ADMIN_KEY}" | curl -s --max-time 45 -X "$1" -H @- -w '\n%{http_code}' "http://${LAN_IP}:${TE_PORT}$2"
}
web() { curl -sk --max-time 60 -w '\n%{http_code}' "$@"; }          # body, newline, code
body_of() { sed '$d'; }
code_of() { tail -n1; }

# ── 5. key separation ─────────────────────────────────────────────────────────
section "5. trusted-edge admin routes: authentication"
C_NONE="$(curl -s -o /dev/null -w '%{http_code}' "http://${LAN_IP}:${TE_PORT}/admin/credential")"
C_WRONG="$(printf 'X-Admin-Key: %s\n' "$(openssl rand -hex 32)" | curl -s -o /dev/null -w '%{http_code}' -H @- "http://${LAN_IP}:${TE_PORT}/admin/credential")"
C_FRAME="$(printf 'X-Edge-Key: %s\n' "${ADMIN_KEY}" | curl -s -o /dev/null -w '%{http_code}' -H @- "http://${LAN_IP}:${TE_PORT}/frame.jpg")"
R="$(edge_call GET /admin/credential)"; C_OK="$(printf '%s' "${R}" | code_of)"
echo "    no key -> ${C_NONE} | wrong key -> ${C_WRONG} | admin key used as X-Edge-Key on /frame.jpg -> ${C_FRAME} | admin key on /admin/credential -> ${C_OK}"
[[ "${C_NONE}" == "401" && "${C_WRONG}" == "401" && "${C_FRAME}" == "401" && "${C_OK}" == "200" ]] \
    || err "admin authentication behaves unexpectedly"
printf '%s' "${R}" | body_of | python3 -c "
import json,sys; d=json.load(sys.stdin)
assert set(d)=={'db_username','lease_ttl_s','lease_duration_s','lease_id','rows_written'}, sorted(d)
assert 'password' not in json.dumps(d).lower()
print('    /admin/credential keys:', sorted(d), '(no password field)')"
ok "admin key separate from the ingest path; /admin/credential returns username, TTL, lease id only"

# ── 6. Widget 1 — identity ────────────────────────────────────────────────────
section "6. Widget 1 — GET /api/vault/identity (real lookup-self)"
R="$(web "${WEBUI}/api/vault/identity")"; [[ "$(printf '%s' "${R}" | code_of)" == "200" ]] || err "/api/vault/identity HTTP $(printf '%s' "${R}" | code_of)"
printf '%s' "${R}" | body_of | python3 -c "
import json,sys
d=json.load(sys.stdin)
for who in ('edge','gateway'):
    t=d[who]
    if 'error' in t: print('   ',who,'->',t); sys.exit(1)
    assert t['display_name'] and t['policies'] and t['expire_time']
    assert 'id' not in t and 'accessor' not in t
    print('   ',who,'| display_name',t['display_name'],'| policies',t['policies'],'| ttl',t['ttl'],'s | expire',t['expire_time'])
" || err "identity endpoint reports an error for a token (see line above)"
ok "both tokens reported with real display_name, policies, TTL, expire_time"

# ── 7. Widget 2 — credential + rotate ─────────────────────────────────────────
section "7. Widget 2 — GET /api/vault/db-credential and Rotate Secret Now"
R="$(web "${WEBUI}/api/vault/db-credential")"; [[ "$(printf '%s' "${R}" | code_of)" == "200" ]] || err "/api/vault/db-credential HTTP $(printf '%s' "${R}" | code_of)"
read -r U0 L0 ROWS0 LEASE0 < <(printf '%s' "${R}" | body_of | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['db_username'],d['lease_ttl_s'],d['rows_written'],d['lease_id'])")
info "BEFORE rotate: username ${U0} | lease ttl ${L0}s | rows_written (since trusted-edge start) ${ROWS0}"
ID0="$(web "${WEBUI}/api/vault/events?limit=1" | body_of | python3 -c "import json,sys;print(json.load(sys.stdin)['events'][0]['id'])")"
info "newest events.id BEFORE rotate: ${ID0}"
RR="$(web -X POST "${WEBUI}/api/vault/rotate-credential")"
RC="$(printf '%s' "${RR}" | code_of)"
echo "    rotate response (HTTP ${RC}): $(printf '%s' "${RR}" | body_of)"
[[ "${RC}" == "200" ]] || err "rotate failed"
read -r OLDU NEWU REVOKED ROWS_WIN ROWS_PRE ROWS_POST WINMS < <(printf '%s' "${RR}" | body_of | python3 -c "
import json,sys;d=json.load(sys.stdin)
print(d['old_username'],d['new_username'],d['old_lease_revoked'],d['rows_written_since_rotate'],d['rows_before_swap'],d['rows_after_swap'],d['rotate_window_ms'])")
[[ "${OLDU}" == "${U0}" && "${NEWU}" != "${OLDU}" ]] || err "rotate did not change the username (old ${OLDU}, new ${NEWU}, was ${U0})"
[[ "${REVOKED}" == "True" ]] || err "old lease was NOT revoked (see revoke_detail above)"
ok "new username issued, old lease revoked: ${OLDU} -> ${NEWU} (window ${WINMS} ms; rows inserted in window: ${ROWS_WIN} = ${ROWS_PRE} before swap + ${ROWS_POST} after swap)"
R="$(web "${WEBUI}/api/vault/db-credential")"
read -r U1 L1 ROWS1 LEASE1 < <(printf '%s' "${R}" | body_of | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['db_username'],d['lease_ttl_s'],d['rows_written'],d['lease_id'])")
[[ "${U1}" == "${NEWU}" ]] || err "status after rotate shows ${U1}, expected ${NEWU}"
info "AFTER rotate: username ${U1} | lease ttl ${L1}s | rows_written ${ROWS1}"
info "waiting up to ${ROWS_WAIT_SEC}s for an INSERT made with the NEW credential (event rate depends on the scene)"
T0=$(date +%s); ROWS_NOW="${ROWS1}"
while (( $(date +%s) - T0 < ROWS_WAIT_SEC )); do
    ROWS_NOW="$(web "${WEBUI}/api/vault/db-credential" | body_of | python3 -c "import json,sys;print(json.load(sys.stdin)['rows_written'])")"
    (( ROWS_NOW > ROWS1 )) && break; sleep 5
done
ID1="$(web "${WEBUI}/api/vault/events?limit=1" | body_of | python3 -c "import json,sys;print(json.load(sys.stdin)['events'][0]['id'])")"
if (( ROWS_NOW > ROWS1 )); then
    ok "INSERTs continue after the swap: rows_written ${ROWS1} -> ${ROWS_NOW}; newest events.id ${ID0} -> ${ID1} (written with ${NEWU})"
    ROWS_VERDICT="continuing (rows_written ${ROWS1}->${ROWS_NOW}, events.id ${ID0}->${ID1})"
else
    warn "NO insert observed within ${ROWS_WAIT_SEC}s after the rotation (static scene?). Continuity NOT demonstrated by traffic in this run. events.id ${ID0} -> ${ID1}"
    ROWS_VERDICT="NOT PROVEN (no traffic in ${ROWS_WAIT_SEC}s; rows in rotate window ${ROWS_WIN})"
fi

# ── 8. Widget 3 — decrypt ─────────────────────────────────────────────────────
section "8. Widget 3 — GET /api/vault/events (ciphertext) and POST /api/vault/decrypt"
EV="$(web "${WEBUI}/api/vault/events?limit=3")"; [[ "$(printf '%s' "${EV}" | code_of)" == "200" ]] || err "/api/vault/events HTTP $(printf '%s' "${EV}" | code_of)"
printf '%s' "${EV}" | body_of | python3 -c "
import json,sys
ev=json.load(sys.stdin)['events']; assert ev
for e in ev: print('   ','id',e['id'],e['event_type'],e['state'],'raw_payload',e['raw_payload'][:24]+'…','datakey',e['encrypted_datakey'][:16]+'…')"
ROW0="$(printf '%s' "${EV}" | body_of | python3 -c "import json,sys;e=json.load(sys.stdin)['events'][0];print(json.dumps({'ciphertext':e['raw_payload'],'encrypted_datakey':e['encrypted_datakey']}))")"
D="$(web -X POST -H 'Content-Type: application/json' --data-binary "${ROW0}" "${WEBUI}/api/vault/decrypt")"
[[ "$(printf '%s' "${D}" | code_of)" == "200" ]] || { echo "    $(printf '%s' "${D}" | body_of)"; err "decrypt failed HTTP $(printf '%s' "${D}" | code_of)"; }
printf '%s' "${D}" | body_of | python3 -c "
import json,sys
p=json.load(sys.stdin)['plaintext']; assert p
print('    plaintext (%d chars, first 80 shown): %s' % (len(p), p[:80].replace(chr(10),' ')))"
ok "real stored row decrypted through control-plane-reader + AES-256-GCM"
TAMPER="$(printf '%s' "${ROW0}" | python3 -c "
import base64,json,sys
d=json.load(sys.stdin); raw=bytearray(base64.b64decode(d['ciphertext'])); raw[-1]^=1
d['ciphertext']=base64.b64encode(bytes(raw)).decode(); print(json.dumps(d))")"
CT="$(web -X POST -H 'Content-Type: application/json' --data-binary "${TAMPER}" "${WEBUI}/api/vault/decrypt" | code_of)"
BADKEY="$(printf '%s' "${ROW0}" | python3 -c "
import json,sys
d=json.load(sys.stdin); d['encrypted_datakey']='vault:v1:'+'AAAA'*20; print(json.dumps(d))")"
CK="$(web -X POST -H 'Content-Type: application/json' --data-binary "${BADKEY}" "${WEBUI}/api/vault/decrypt" | code_of)"
echo "    tampered ciphertext -> HTTP ${CT} (expected 422) | forged datakey -> HTTP ${CK} (expected 502)"
[[ "${CT}" == "422" && "${CK}" == "502" ]] || err "negative decrypt tests behaved unexpectedly"
ok "tampered payload rejected by AES-GCM; forged datakey rejected by Transit"

# ── 9. secret scan ────────────────────────────────────────────────────────────
section "9. Secret scan: admin key and AppRole secret_id"
SCAN_PY="$(mktemp /tmp/.cr-scan.XXXXXX)"
cat > "${SCAN_PY}" <<'PY'
import json, os, subprocess, sys
src = "/etc/webui-vault"
needles = [open(f"{src}/admin-key").read().strip().encode(), json.load(open(f"{src}/control-reader"))["secret_id"].encode()]
hits = 0
def has(blob): return any(n in blob for n in needles)
j = subprocess.run(["journalctl", "--since", os.environ["STAGE_START"], "--no-pager", "-o", "cat"], capture_output=True)
if has(j.stdout): print("HIT  journal since stage start"); hits += 1
for pid in os.listdir("/proc"):
    if pid.isdigit():
        for f in ("cmdline",) + (("environ",) if pid in (os.environ["WEBUI_PID"], os.environ["TE_PID"]) else ()):
            try:
                if has(open(f"/proc/{pid}/{f}", "rb").read()): print(f"HIT  /proc/{pid}/{f}"); hits += 1
            except OSError: pass
skip = {".venv", "venv", ".git", "models", "node_modules", "__pycache__", "checkpoints", "engines", "proc", "sys"}
n = 0
for root in ("/etc", "/opt/trusted-edge", "/home/jetson", "/tmp", "/var/tmp", "/var/log", "/root", os.environ["REPO_DIR"]):
    for d, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = [x for x in dirs if x not in skip and os.path.join(d, x) != src]
        for fn in files:
            p = os.path.join(d, fn)
            try:
                if os.path.islink(p) or os.path.getsize(p) > 5 * 1024 * 1024: continue
                n += 1
                if has(open(p, "rb").read()): print(f"HIT  {p}"); hits += 1
            except OSError: pass
print(f"scanned: journal since {os.environ['STAGE_START']}, every /proc/*/cmdline, environ of WebUI+trusted-edge, {n} files; hits={hits}")
sys.exit(1 if hits else 0)
PY
set +e
sudocmd env "STAGE_START=${STAGE_START}" "WEBUI_PID=$(systemctl show -p MainPID --value "${WEBUI_SVC}")" \
    "TE_PID=$(systemctl show -p MainPID --value "${SVC}")" "REPO_DIR=${REPO_DIR}" python3 "${SCAN_PY}"
SCAN_RC=$?
set -e
rm -f "${SCAN_PY}"
[[ ${SCAN_RC} -eq 0 ]] || err "admin key or secret_id FOUND outside ${CRED_DIR_SRC} (paths above)"
ok "zero occurrences of the admin key / secret_id outside ${CRED_DIR_SRC} (scope above; /run/credentials copies are by design not scanned)"

# ── Summary ───────────────────────────────────────────────────────────────────
section "RESULT (record in CHANGELOG.md, Session 5-3b)"
cat <<EOF
  identity      edge + gateway tokens reported by lookup-self (section 6)
  rotate        ${OLDU} -> ${NEWU} ; revoked=${REVOKED} ; window ${WINMS} ms ; rows in window ${ROWS_WIN} (${ROWS_PRE} before swap, ${ROWS_POST} after)
  rows          ${ROWS_VERDICT}
  old lease     ${LEASE0}
  new lease     ${LEASE1}
  CHECK ON MAC  vault lease lookup <old lease>  -> must fail ("invalid lease");  pg_roles must not contain ${OLDU}
  decrypt       real row decrypted; tampered payload 422; forged datakey 502
  secret scan   admin key + secret_id: zero hits outside ${CRED_DIR_SRC}
EOF
ok "Stage 5-3b complete (marker 15_vault_widgets is written by setup-jetson.sh)"
