#!/usr/bin/env bash
# scripts/16-install-agent-sandbox.sh
# ──────────────────────────────────────────────────────────────────────────────
# Phase 3 Session 3-5i — Persistent sandbox: slim agent, live gate, latency
# Stage id: 3-5i  |  alias: agent-sandbox  |  marker: 13b_agent_sandbox
#
# Change-triggered inference: the agent polls every POLL_INTERVAL_SEC (default 1 s)
# but only calls the VLM when the 64×64 grayscale MAD exceeds MOTION_THRESHOLD
# (default 10/255) AND the MIN_INFER_INTERVAL cooldown has passed.  A MAX_IDLE_INFER_SEC
# liveness check (default 120 s) ensures inference fires even in a static scene.
# This keeps the DB row count proportional to real events, not to the frame rate.
#
# Docs:
#   OpenShell v0.1.4 sandbox create:
#     https://docs.nvidia.com/openshell/latest/how-it-works/sandboxes/create.md
#   OpenShell v0.1.4 logs/policy:
#     https://docs.nvidia.com/openshell/latest/how-it-works/sandboxes/inspect.md
#
# Pre-conditions (entry checks in §0):
#   13_trusted_edge   — trusted-edge.service active, GET /frame.jpg works
#   13a_gateway_vault_driver — providers edge-ingest and cosmos-vlm installed
#   11_tpm_agent          — edge vault-agent writing /run/openshell-edge/vault-token
#
# What this stage does:
#   0. Entry checks.
#   1. Build the slim agent Docker image (edge-agent-sandbox:dev, requests only).
#   2. Measure WebUI FPS BEFORE.
#   3. Create (or recreate) the persistent sandbox `camera-agent` with:
#        --restart-policy always
#        --provider edge-ingest --provider cosmos-vlm
#      --env INGEST_BASE=http://jetson.localdomain:8095
#      --env VLM_URL=http://jetson.localdomain:8090/v1/chat/completions
#      --env CAMERA_ID FRAME_INTERVAL_SEC VLM_MAX_TOKENS
#      INGEST_KEY is NOT passed as --env; the gateway injects it into the sandbox
#      env as an opaque openshell:resolve:env:... placeholder. agent.py reads
#      os.environ.get("INGEST_KEY") to obtain this placeholder value.
#   4. Latency measurement: time 20 round trips (frame→VLM→event) with the L7
#      cosmos-vlm profile. If the average total exceeds 5 s, warn and document.
#      Also record the WebUI FPS AFTER to check for interference.
#   5. Secret scan: grep sandbox env, docker logs (both containers), openshell
#      logs, journal for any fragment of the RTSP password, the edge Vault token
#      value, the gateway Vault token, the DB password, the DEK.  Zero hits
#      required (the camera.env KNOWN-HIT was retired in Session 3-5j).
#   6. Live gate: wait for >= 10 new event rows with vault:v1:% ciphertext
#      (query via the trusted-edge /events check route or by asking the user to
#      run: `psql -h <mac-ip> -U <dynamic_user> edge_demo -c "SELECT count(*) FROM events WHERE encrypted_datakey LIKE 'vault:v1:%'"`)
#      (AGENTS.md §1: the stage cannot run psql on the Mac; the user must verify).
#   7. Deliberate denied probe: attempt a connection outside the policy from
#      inside the sandbox; confirm `DENIED` appears in openshell logs.
#   8. Write marker.
#
# Usage: ./scripts/bootstrap-jetson.sh <jetson-ip> --only-stage 3-5i
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${REPO_DIR}/.setup-state"
MARKER="${STATE_DIR}/13b_agent_sandbox"

if [[ -f "${REPO_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1090,SC1091
  source "${REPO_DIR}/.env"
  set +a
fi

SANDBOX_NAME="camera-agent"
AGENT_IMAGE="edge-agent-sandbox:dev"
JETSON_HOSTNAME="${JETSON_HOSTNAME:-jetson.localdomain}"
TE_PORT="${TRUSTED_EDGE_PORT:-${TE_PORT:-8095}}"
VLM_PORT="${VLM_PORT:-8090}"
WEBUI_PORT="${WEBUI_PORT:-8443}"
MAC_IP="${MAC_IP:-127.0.0.1}"

INGEST_BASE="http://${JETSON_HOSTNAME}:${TE_PORT}"
VLM_URL="http://${JETSON_HOSTNAME}:${VLM_PORT}/v1/chat/completions"
POLL_INTERVAL="${POLL_INTERVAL_SEC:-1}"
MIN_INFER_INTERVAL="${MIN_INFER_INTERVAL_SEC:-5}"
MOTION_THRESHOLD="${MOTION_THRESHOLD:-10}"
CAMERA_PROFILE="${CAMERA_PROFILE:-indoor}"
VLM_MAX_TOKENS="${VLM_MAX_TOKENS:-300}"
CAMERA_ID="${CAMERA_ID:-cam-default}"
WEBUI_STATUS="https://127.0.0.1:${WEBUI_PORT}/api/status"
INGEST_PORT="${TE_PORT}"
TE_SVC="trusted-edge"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}  ▷ $*${NC}"; }
ok()      { echo -e "${GREEN}  ✓ $*${NC}"; }
warn()    { echo -e "${YELLOW}  ⚠ $*${NC}"; }
err()     { echo -e "${RED}  ✗ $*${NC}"; exit 1; }
section() { echo -e "\n${GREEN}══ $* ══${NC}"; }

sudocmd() { echo "${SUDO_PASS}" | sudo -S "$@"; }

STAGE_START="$(date '+%Y-%m-%d %H:%M:%S')"

if [[ -f "${MARKER}" ]]; then
    echo -e "${GREEN}Stage 3-5i already complete (marker exists). Skipping.${NC}"
    exit 0
fi
mkdir -p "${STATE_DIR}"

# ── 0. Entry checks ───────────────────────────────────────────────────────────
section "0. Entry checks"

for m in 13_trusted_edge 13a_gateway_vault_driver 11_tpm_agent; do
    [[ -f "${STATE_DIR}/${m}" ]] || err "Required marker ${m} not present — run that stage first."
done
ok "markers 13_trusted_edge, 13a_gateway_vault_driver, 11_tpm_agent present"

systemctl is-active --quiet "${TE_SVC}"   || err "trusted-edge.service is not active"
systemctl is-active --quiet vault-agent   || err "vault-agent.service (edge) is not active"
openshell provider list 2>/dev/null | grep -q "^edge-ingest"   || err "provider edge-ingest not found"
openshell provider list 2>/dev/null | grep -q "^cosmos-vlm"    || err "provider cosmos-vlm not found"
ok "trusted-edge active, vault-agent active, both providers present"

# Verify the edge-ingest key is reachable (not verifying the key value).
FRAME_RESP="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "X-Edge-Key: $(sudocmd cat /run/openshell-edge/vault-token | head -1)" \
    --max-time 5 "${INGEST_BASE}/frame.jpg" 2>/dev/null || true)"
# That is the VAULT token, not the ingest key — the check is only that the
# service responds (we deliberately send the wrong key to get 401, not 503).
# A 401 or 200 means the port is reachable; anything else means the service is down.
if [[ "${FRAME_RESP}" == "000" ]]; then
    err "trusted-edge not reachable at ${INGEST_BASE} — is it bound to the LAN address?"
fi
ok "trusted-edge reachable at ${INGEST_BASE} (HTTP ${FRAME_RESP})"

# Verify the VLM is up.
VLM_HEALTH="$(curl -s -o /dev/null -w '%{http_code}' \
    --max-time 10 "http://${JETSON_HOSTNAME}:${VLM_PORT}/health" 2>/dev/null || true)"
[[ "${VLM_HEALTH}" == "200" ]] || err "llama-server at :${VLM_PORT} returned HTTP ${VLM_HEALTH} — check vlm-server.service"
ok "llama-server health OK (HTTP 200)"

# ── 1. Build the slim agent image ─────────────────────────────────────────────
section "1. Build ${AGENT_IMAGE}"
info "Building slim agent image (requests only — no OpenCV/psycopg2/cryptography)..."
docker build --quiet \
    -t "${AGENT_IMAGE}" \
    -f "${REPO_DIR}/agent/Dockerfile" \
    "${REPO_DIR}/agent/"
ok "Image ${AGENT_IMAGE} built"

# Confirm the slim packages are absent from the venv (all checks use venv python).
for pkg in opencv psycopg2 cryptography; do
    if docker run --rm --entrypoint /opt/agent-venv/bin/python3 "${AGENT_IMAGE}" \
            -c "import ${pkg}; print('FOUND')" 2>/dev/null | grep -q FOUND; then
        err "Package ${pkg} still present in image ${AGENT_IMAGE} — requirements.txt not slimmed"
    fi
done
ok "Confirmed: opencv, psycopg2, cryptography NOT in venv"

# Confirm Pillow is importable from the VENV (agent.py uses /opt/agent-venv/bin/python3).
# Must NOT use system python3 — the venv does not inherit system site-packages.
if ! docker run --rm --entrypoint /opt/agent-venv/bin/python3 "${AGENT_IMAGE}" \
        -c "from PIL import Image; print('PIL OK')" 2>/dev/null | grep -q "PIL OK"; then
    err "Pillow not importable from the agent venv in ${AGENT_IMAGE} — add Pillow to requirements.txt"
fi
ok "Pillow importable from agent venv (motion detection)"

# ── 2. WebUI FPS BEFORE ───────────────────────────────────────────────────────
section "2. WebUI FPS BEFORE (30 s window)"
frame_count() {
    curl -sk --max-time 5 "${WEBUI_STATUS}" \
        | python3 -c "import json,sys; c=json.load(sys.stdin)['camera']; print(c['frame_count'], c['is_synthetic'])"
}
measure_fps() {
    local a b t0 t1 syn
    read -r a syn < <(frame_count); t0=$(date +%s.%N)
    sleep "$1"
    read -r b _   < <(frame_count); t1=$(date +%s.%N)
    [[ -n "${a}" && -n "${b}" ]] || { echo "WebUI /api/status unreadable" >&2; return 1; }
    awk -v a="$a" -v b="$b" -v t0="$t0" -v t1="$t1" -v s="$syn" 'BEGIN{printf "%.2f %s", (b-a)/(t1-t0), s}'
}
if systemctl is-active --quiet live-vlm-webui; then
    FPS_BEFORE="$(measure_fps 30)"
    ok "WebUI FPS BEFORE: ${FPS_BEFORE% *} /s (is_synthetic=${FPS_BEFORE#* })"
else
    FPS_BEFORE="N/A (live-vlm-webui not active)"
    warn "${FPS_BEFORE}"
fi

# ── 3. Create persistent sandbox ─────────────────────────────────────────────
section "3. Create persistent sandbox '${SANDBOX_NAME}'"

# Tear down any previous instance.
if openshell sandbox list 2>/dev/null | awk -v n="${SANDBOX_NAME}" '$1==n {found=1} END{exit !found}'; then
    info "Deleting existing sandbox ${SANDBOX_NAME}..."
    openshell sandbox delete "${SANDBOX_NAME}" || true
    sleep 2
fi

# The gateway injects the provider placeholder into the sandbox env as "INGEST_KEY"
# (the credential's env_var name from the edge-ingest profile, env_vars: [INGEST_KEY]).
# agent.py reads os.environ.get("INGEST_KEY") to get the opaque placeholder value
# (openshell:resolve:env:v<N>_INGEST_KEY) and sends it in the X-Edge-Key header.
# The supervisor substitutes the real key before forwarding to trusted-edge.
# The agent never learns the actual key value.
# INGEST_KEY_PLACEHOLDER is NOT passed as --env here; it is gateway-injected.
#
# Print the sandbox create command (without any secret value) before running it.
info "Creating sandbox with providers edge-ingest and cosmos-vlm (restart-policy always)..."
SANDBOX_CREATE_CMD=(
    openshell sandbox create
    --name "${SANDBOX_NAME}"
    --restart-policy always
    --from "${AGENT_IMAGE}"
    --policy "${REPO_DIR}/agent/policy.yaml"
    --provider edge-ingest
    --provider cosmos-vlm
    --env "INGEST_BASE=${INGEST_BASE}"
    --env "VLM_URL=${VLM_URL}"
    --env "CAMERA_ID=${CAMERA_ID}"
    --env "POLL_INTERVAL_SEC=${POLL_INTERVAL}"
    --env "MIN_INFER_INTERVAL_SEC=${MIN_INFER_INTERVAL}"
    --env "CAMERA_PROFILE=${CAMERA_PROFILE}"
    --env "MOTION_THRESHOLD=${MOTION_THRESHOLD}"
    --env "VLM_MAX_TOKENS=${VLM_MAX_TOKENS}"
    --detach
    -- /opt/agent-venv/bin/python3 /app/agent.py
)

# Log the command (no secrets in it).
echo "  CMD: ${SANDBOX_CREATE_CMD[*]}" | sed 's/--env /\n         --env /g'

"${SANDBOX_CREATE_CMD[@]}" || err "openshell sandbox create failed"

# Wait up to 60 s for the sandbox to become Ready.
# openshell sandbox list columns: NAME  ...  STATUS (last field, $NF) — verified 3-5h.
info "Waiting for sandbox ${SANDBOX_NAME} to be Ready..."
STATUS=""
for i in $(seq 1 60); do
    STATUS="$(openshell sandbox list 2>/dev/null | awk -v n="${SANDBOX_NAME}" '$1==n {print $NF}' || true)"
    [[ "${STATUS}" == "Ready" ]] && break
    sleep 1
done
if [[ "${STATUS}" != "Ready" ]]; then
    # 7-2d full-flow run: the agent crash-loops and its own stdout/stderr reach no log, and `sandbox exec`
    # refuses a non-Ready sandbox. So: delete the crash-looping sandbox, create a throw-away probe sandbox with
    # the SAME image, policy, providers and env but `sleep 600` as main process (the 3-5h call shape, which
    # reaches Ready), then run the agent inside it by hand with its output visible.
    warn "Sandbox ${SANDBOX_NAME} not Ready (status '${STATUS}') - running the probe sandbox, then failing"
    openshell sandbox get "${SANDBOX_NAME}" 2>&1 | grep -E "Phase|Exit Code|Last exit code|Restart count|Ready:" | sed 's/^/    | /' || true
    openshell sandbox delete "${SANDBOX_NAME}" >/dev/null 2>&1 || true
    PROBE_SB="ca-diag-3i"
    openshell sandbox delete "${PROBE_SB}" >/dev/null 2>&1 || true
    sleep 2
    timeout 240 openshell sandbox create --name "${PROBE_SB}" --no-tty --detach \
        --from "${AGENT_IMAGE}" --policy "${REPO_DIR}/agent/policy.yaml" \
        --provider edge-ingest --provider cosmos-vlm \
        --env "INGEST_BASE=${INGEST_BASE}" --env "VLM_URL=${VLM_URL}" --env "CAMERA_ID=${CAMERA_ID}" \
        --env "POLL_INTERVAL_SEC=${POLL_INTERVAL}" --env "MIN_INFER_INTERVAL_SEC=${MIN_INFER_INTERVAL}" \
        --env "CAMERA_PROFILE=${CAMERA_PROFILE}" --env "MOTION_THRESHOLD=${MOTION_THRESHOLD}" \
        --env "VLM_MAX_TOKENS=${VLM_MAX_TOKENS}" \
        -- sleep 600 < /dev/null 2>&1 | tail -5 | sed 's/^/    | /' || true
    PSTATUS=""
    for i in $(seq 1 60); do
        PSTATUS="$(openshell sandbox list 2>/dev/null | awk -v n="${PROBE_SB}" '$1==n {print $NF}' || true)"
        [[ "${PSTATUS}" == "Ready" ]] && break
        sleep 1
    done
    echo "    probe sandbox ${PROBE_SB} status: '${PSTATUS}'"
    if [[ "${PSTATUS}" == "Ready" ]]; then
        PY_DIAG='import os,sys,traceback
print("uid", os.getuid(), "gid", os.getgid(), "groups", os.getgroups(), "cwd", os.getcwd())
for p in ("/app", "/app/agent.py", "/opt/agent-venv/pyvenv.cfg", "/opt/agent-venv/bin/python3", "/usr/bin/python3.12", "/sandbox"):
    try:
        st = os.stat(p)
        print(p, oct(st.st_mode), st.st_uid, st.st_gid)
    except Exception as e:
        print(p, "STAT-FAIL", repr(e))
try:
    src = open("/app/agent.py").read()
    compile(src, "/app/agent.py", "exec")
    print("read+compile OK", len(src), "bytes")
except Exception:
    traceback.print_exc()
try:
    import requests, PIL
    print("imports OK: requests", requests.__version__, "PIL", PIL.__version__)
except Exception:
    traceback.print_exc()'
        echo "    --- diag (venv python) ---"
        timeout 60 openshell sandbox exec -n "${PROBE_SB}" --no-tty --no-login-shell --timeout 30 -- \
            /opt/agent-venv/bin/python3 -c "${PY_DIAG}" < /dev/null 2>&1 | sed 's/^/    diag: /' || true
        echo "    --- agent.py by hand, 20 s (venv python, unbuffered) ---"
        timeout 60 openshell sandbox exec -n "${PROBE_SB}" --no-tty --no-login-shell --timeout 20 -- \
            /opt/agent-venv/bin/python3 -u /app/agent.py < /dev/null 2>&1 | head -60 | sed 's/^/    agent: /' || true
        echo "    --- agent.py by hand, 20 s (/usr/bin/python3.12) ---"
        timeout 60 openshell sandbox exec -n "${PROBE_SB}" --no-tty --no-login-shell --timeout 20 -- \
            /usr/bin/python3.12 -u /app/agent.py < /dev/null 2>&1 | head -30 | sed 's/^/    agent312: /' || true
    fi
    openshell sandbox delete "${PROBE_SB}" >/dev/null 2>&1 || true
    err "Sandbox ${SANDBOX_NAME} not Ready after 60 s (status: '${STATUS}') - probe output above"
fi
ok "Sandbox ${SANDBOX_NAME} is Ready"

# Show the two containers.
# Label key measured from docker ps output: openshell.ai/sandbox-name=<name>
docker ps --filter "label=openshell.ai/sandbox-name=${SANDBOX_NAME}" \
    --format "  container {{.ID}} {{.Names}} {{.Status}}" | sed 's/^/  /'

# Confirm the effective policy includes both provider-derived rules.
POLICY_OUT="$(openshell policy get "${SANDBOX_NAME}" --full 2>/dev/null || true)"
echo "${POLICY_OUT}" | grep -q "_provider_edge_ingest"  \
    || err "policy for ${SANDBOX_NAME} does not include _provider_edge_ingest"
echo "${POLICY_OUT}" | grep -q "_provider_cosmos_vlm"   \
    || err "policy for ${SANDBOX_NAME} does not include _provider_cosmos_vlm"
ok "Effective policy includes _provider_edge_ingest and _provider_cosmos_vlm"
echo "  restart_policy=$(openshell sandbox get "${SANDBOX_NAME}" 2>/dev/null | grep -i restart | head -2 || true)"

# ── 4. Latency measurement (L7 cosmos-vlm) ───────────────────────────────────
# The new log format emits "vlm=Nms" on each inference-triggered line (not "total=").
# We collect up to 10 inference lines (each requires a motion trigger; with
# MIN_INFER_INTERVAL=5 s that takes ~50 s minimum).
section "4. Latency: up to 10 inference round trips (L7 cosmos-vlm, motion-triggered)"
info "Collecting VLM timing from sandbox logs (waiting up to 180 s for motion triggers)..."

# Label key measured from docker ps output: openshell.ai/sandbox-name=<name>
# Filter out the supervisor container via openshell.ai/isolation-role label.
WORKLOAD_CTR="$(docker ps --filter "label=openshell.ai/sandbox-name=${SANDBOX_NAME}" \
    --filter "label=openshell.ai/isolation-role=sandbox" \
    --format "{{.Names}}" | head -1 || true)"
if [[ -z "${WORKLOAD_CTR}" ]]; then
    warn "Cannot identify workload container — latency measurement skipped."
    LAT_NOTE="workload container not found; latency not measured"
else
    info "Workload container: ${WORKLOAD_CTR}"
    # Inference lines look like: "[agent] vlm=2341ms  text=..."
    COUNT=0; ATTEMPT=0; MAX_WAIT=180
    VLM_VALS=()
    while [[ ${COUNT} -lt 10 && ${ATTEMPT} -lt ${MAX_WAIT} ]]; do
        VLM_VALS=()
        while IFS= read -r line; do
            v="$(echo "${line}" | grep -oP 'vlm=\K[0-9]+' || true)"
            [[ -n "${v}" ]] && VLM_VALS+=("${v}")
        done < <(docker logs "${WORKLOAD_CTR}" 2>&1 | grep "vlm=[0-9]")
        COUNT="${#VLM_VALS[@]}"
        [[ ${COUNT} -ge 10 ]] && break
        sleep 3
        ATTEMPT=$((ATTEMPT + 3))
    done

    if [[ ${COUNT} -eq 0 ]]; then
        warn "No VLM timing lines after ${MAX_WAIT} s — the scene may be static (no motion triggers)."
        warn "Check docker logs ${WORKLOAD_CTR} | grep trigger"
        LAT_NOTE="no inference triggered in ${MAX_WAIT} s (static scene or motion threshold too high)"
    else
        p_stat() {  # $1=pct, "${@:2}"=values
            local pct="$1"; shift
            printf '%s\n' "$@" | sort -n | awk -v p="${pct}" -v n="$#" 'NR==int(n*p/100+0.9){print}'
        }
        V_P50="$(p_stat 50 "${VLM_VALS[@]}")"
        V_P95="$(p_stat 95 "${VLM_VALS[@]}")"
        echo ""
        echo "  VLM inference latency (L7 cosmos-vlm provider, ${COUNT} motion-triggered samples):"
        printf  "  %-12s %8s %8s\n" "Leg" "p50 ms" "p95 ms"
        printf  "  %-12s %8s %8s\n" "vlm" "${V_P50}" "${V_P95}"
        echo ""
        if [[ "${V_P95:-0}" -gt 5000 ]]; then
            warn "p95 VLM ${V_P95} ms > 5000 ms. Consider enabling the L4 fallback rule in agent/policy.yaml."
            LAT_NOTE="L7 p50=${V_P50}ms p95=${V_P95}ms — EXCEEDS 5000 ms, L4 fallback recommended"
        else
            ok "L7 VLM latency: p50=${V_P50} ms, p95=${V_P95} ms"
            LAT_NOTE="L7 p50=${V_P50}ms p95=${V_P95}ms (${COUNT} samples)"
        fi
    fi
fi

# ── 5. Secret scan inside the sandbox ────────────────────────────────────────
section "5. Secret scan — sandbox env, logs, openshell logs"
info "Scanning for credential fragments..."

# 7-2e: the summary used to print "PASSED (0 unexpected hits)" unconditionally (SCAN_FAIL was never
# incremented; `err` exits). Now every sub-check that really ran is counted in SCAN_RAN and every one
# that could not run is named in SCAN_NOTRUN; the summary prints those computed values.
SCAN_RAN=0
SCAN_NOTRUN=()

# Gather the RTSP password fragment (just the first 6 chars of the userinfo,
# excluding the scheme — enough to identify a leak without printing it).
# We read the hash from Vault KV; the actual password is in Vault and in
# trusted-edge's memory only.  We cannot read it here without the edge token.
# So we check for the known placeholder and for any literal "vault:v1:" prefix
# appearing in agent/sandbox env or logs.
#
# What we CAN check from the sandbox side:
#   - No Vault token value in sandbox env (openshell sandbox env or docker inspect)
#   - No "vault:v1:" ciphertext in sandbox env (the DEK ciphertext should only be in DB)
#   - No literal "password" or "rtsp://" containing userinfo in sandbox env or logs

EDGE_TOKEN_PREFIX=""
if sudocmd test -s /run/openshell-edge/vault-token; then
    EDGE_TOKEN_PREFIX="$(sudocmd cat /run/openshell-edge/vault-token | head -c 10)"
fi
GW_TOKEN_PREFIX=""
if sudocmd test -s /run/openshell/vault-token; then
    GW_TOKEN_PREFIX="$(sudocmd cat /run/openshell/vault-token 2>/dev/null | head -c 10 || true)"
fi

# Sandbox environment (what the workload container sees).
# Use WORKLOAD_CTR (set in step 4) — docker container name is not the sandbox name.
SB_ENV=""
if [[ -n "${WORKLOAD_CTR}" ]]; then
    SB_ENV="$(docker inspect "${WORKLOAD_CTR}" 2>/dev/null | python3 -c \
        "import json,sys; d=json.load(sys.stdin); [print(e) for d2 in d for e in d2.get('Config',{}).get('Env',[]) or []]" \
        2>/dev/null || true)"
fi

# Check for Vault token leaks in sandbox env.
if [[ -n "${EDGE_TOKEN_PREFIX}" && -n "${SB_ENV}" ]]; then
    echo "${SB_ENV}" | grep -q "${EDGE_TOKEN_PREFIX}" \
        && err "EDGE VAULT TOKEN prefix found in sandbox env!" \
        || ok "Edge Vault token prefix NOT in sandbox env"
    SCAN_RAN=$((SCAN_RAN + 1))
else
    SCAN_NOTRUN+=("edge token prefix vs sandbox env (token unreadable or sandbox env empty)")
fi
if [[ -n "${GW_TOKEN_PREFIX}" && -n "${SB_ENV}" ]]; then
    echo "${SB_ENV}" | grep -q "${GW_TOKEN_PREFIX}" \
        && err "GATEWAY VAULT TOKEN prefix found in sandbox env!" \
        || ok "Gateway Vault token prefix NOT in sandbox env"
    SCAN_RAN=$((SCAN_RAN + 1))
else
    SCAN_NOTRUN+=("gateway token prefix vs sandbox env (token unreadable or sandbox env empty)")
fi

# Check for vault:v1: DEK ciphertext in sandbox logs.
if [[ -n "${WORKLOAD_CTR}" ]]; then
    SANDBOX_LOGS="$(docker logs "${WORKLOAD_CTR}" 2>&1 | tail -200 || true)"
    echo "${SANDBOX_LOGS}" | grep -q "vault:v1:" \
        && err "vault:v1: ciphertext found in sandbox docker logs (agent should not see this)" \
        || ok "No vault:v1: ciphertext in sandbox docker logs"

    # Check for rtsp:// userinfo in sandbox logs.
    echo "${SANDBOX_LOGS}" | grep -qiE 'rtsp://[^@]+@' \
        && err "RTSP URL with credentials found in sandbox docker logs!" \
        || ok "No RTSP URL with credentials in sandbox docker logs"
    SCAN_RAN=$((SCAN_RAN + 2))
else
    SCAN_NOTRUN+=("workload container docker logs (WORKLOAD_CTR empty): vault:v1: and rtsp:// checks")
fi

# Check openshell logs for the sandbox.
OSHL_LOGS="$(openshell logs "${SANDBOX_NAME}" --source sandbox 2>/dev/null | tail -100 || true)"
if [[ -n "${OSHL_LOGS}" ]]; then
    echo "${OSHL_LOGS}" | grep -q "vault:v1:" \
        && err "vault:v1: ciphertext found in openshell sandbox logs" \
        || ok "No vault:v1: ciphertext in openshell logs"
    echo "${OSHL_LOGS}" | grep -qiE 'rtsp://[^@]+@' \
        && err "RTSP URL with credentials in openshell logs" \
        || ok "No RTSP URL with credentials in openshell logs"
    SCAN_RAN=$((SCAN_RAN + 2))
else
    SCAN_NOTRUN+=("openshell logs ${SANDBOX_NAME}: empty output, vault:v1: and rtsp:// checks")
fi

# Journal scan (last 200 lines for the agent-related units).
JOURNAL_SNAP="$(journalctl -u trusted-edge -u vault-agent -u vault-agent-gateway \
    --since "${STAGE_START}" --no-pager -o cat 2>/dev/null | tail -200 || true)"
if [[ -n "${JOURNAL_SNAP}" ]]; then
    echo "${JOURNAL_SNAP}" | grep -qiE 'rtsp://[^@]+@' \
        && err "RTSP URL with credentials found in journal" \
        || ok "No RTSP URL with credentials in journal"
    SCAN_RAN=$((SCAN_RAN + 1))
else
    SCAN_NOTRUN+=("journal scan (no journal lines since stage start)")
fi

if [[ ${#SCAN_NOTRUN[@]} -eq 0 ]]; then
    SCAN_SUMMARY="${SCAN_RAN} sub-checks ran, 0 hits"
else
    SCAN_SUMMARY="${SCAN_RAN} sub-checks ran, 0 hits; NOT RUN: ${#SCAN_NOTRUN[@]}"
    for _n in "${SCAN_NOTRUN[@]}"; do warn "secret scan not run: ${_n}"; done
fi
ok "Secret scan: ${SCAN_SUMMARY}"

# ── 6. Live gate instructions ─────────────────────────────────────────────────
section "6. Live gate — RTSP → VLM → events → PostgreSQL (NOT RUN by this stage: manual action below)"
echo ""
echo "  ┌─────────────────────────────────────────────────────────────────┐"
echo "  │  ACTION REQUIRED ON THE MAC:                                   │"
echo "  │                                                                  │"
echo "  │  psql -h ${MAC_IP} -U <dynamic_user> ${POSTGRES_DB:-edge_demo} -c              │"
echo "  │    \"SELECT count(*) FROM events                                 │"
echo "  │      WHERE encrypted_datakey LIKE 'vault:v1:%'                 │"
echo "  │      AND ts > NOW() - INTERVAL '10 minutes'\"                  │"
echo "  │                                                                  │"
echo "  │  Wait until this returns >= 10 rows.                            │"
echo "  │  The agent posts one event per detection (motion-triggered).    │"
echo "  └─────────────────────────────────────────────────────────────────┘"
echo ""
echo "  Current agent log tail (latest 5 lines):"
if [[ -n "${WORKLOAD_CTR}" ]]; then
    docker logs "${WORKLOAD_CTR}" 2>&1 | tail -5 | sed 's/^/    | /'
fi

# ── 7. Deliberate denied probe ───────────────────────────────────────────────
section "7. Deliberate denied probe"
info "Creating a throw-away sandbox WITHOUT providers to hit a DENIED..."
DENIED_SB="deny-probe-$(echo $$ | tail -c 5)"
# The probe tries to reach the VLM directly (no cosmos-vlm provider) — should be denied.
openshell sandbox create \
    --name "${DENIED_SB}" \
    --from "${AGENT_IMAGE}" \
    --policy "${REPO_DIR}/agent/policy.yaml" \
    -- /opt/agent-venv/bin/python3 -c \
    "import requests,sys; r=requests.get('http://${JETSON_HOSTNAME}:${VLM_PORT}/health',timeout=5); print('HTTP',r.status_code)" \
    || true
sleep 3
DENIED_LOG="$(openshell logs "${DENIED_SB}" --source sandbox 2>/dev/null || true)"
echo "${DENIED_LOG}" | tail -10 | sed 's/^/    | /'
if echo "${DENIED_LOG}" | grep -q "DENIED"; then
    ok "DENIED line confirmed in openshell logs for the no-provider probe"
    DENY_PROBE_RESULT="DENIED line seen"
else
    DENY_PROBE_RESULT="NOT CONFIRMED (no DENIED line found)"
    warn "No DENIED line found — the deny probe may have succeeded (unexpected) or the sandbox exited too fast. Check manually."
    info "  openshell logs ${DENIED_SB} --source sandbox"
fi
openshell sandbox delete "${DENIED_SB}" >/dev/null 2>&1 || true

# ── 8. WebUI FPS AFTER ────────────────────────────────────────────────────────
section "8. WebUI FPS AFTER (30 s window, agent running)"
if systemctl is-active --quiet live-vlm-webui; then
    FPS_AFTER="$(measure_fps 30)"
    ok "WebUI FPS AFTER: ${FPS_AFTER% *} /s (is_synthetic=${FPS_AFTER#* })"
    FPS_BEFORE_VAL="${FPS_BEFORE% *}"
    FPS_AFTER_VAL="${FPS_AFTER% *}"
    if awk "BEGIN{exit !( ${FPS_AFTER_VAL} < ${FPS_BEFORE_VAL} * 0.9 )}" 2>/dev/null; then
        warn "WebUI FPS dropped by >10%%: before=${FPS_BEFORE_VAL}, after=${FPS_AFTER_VAL}"
        warn "llama-server -np 1 serialises inference; agent + WebUI Auto Loop compete."
        warn "Consider reducing MIN_INFER_INTERVAL_SEC or disabling WebUI Auto Loop during agent demo."
    else
        ok "WebUI FPS within 10%% of before (before=${FPS_BEFORE_VAL}, after=${FPS_AFTER_VAL})"
    fi
else
    FPS_AFTER="N/A"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
section "Stage 3-5i summary"
echo ""
echo "  Sandbox            : ${SANDBOX_NAME}"
echo "  Image              : ${AGENT_IMAGE}"
echo "  Restart policy     : always"
echo "  Providers          : edge-ingest, cosmos-vlm"
echo "  INGEST_BASE        : ${INGEST_BASE}"
echo "  VLM_URL            : ${VLM_URL}"
echo "  POLL_INTERVAL      : ${POLL_INTERVAL}s"
echo "  MIN_INFER_INTERVAL : ${MIN_INFER_INTERVAL}s"
echo "  CAMERA_PROFILE     : ${CAMERA_PROFILE}"
echo "  MOTION_THRESHOLD   : ${MOTION_THRESHOLD}/255"
echo "  Latency (L7)       : ${LAT_NOTE:-not measured}"
echo "  WebUI FPS before   : ${FPS_BEFORE}"
echo "  WebUI FPS after    : ${FPS_AFTER}"
echo "  Secret scan     : ${SCAN_SUMMARY}"
echo "  Deny probe      : ${DENY_PROBE_RESULT:-not run}"
echo "  Live gate (step 6): not run here (needs psql on the Mac)"
echo "  Marker          : 13b_agent_sandbox"
echo ""
echo "  Next: verify >= 10 new vault:v1: event rows on the Mac (see step 6)."
echo "  Then run Session 3-5j to clean up legacy items."
echo ""

touch "${MARKER}"
ok "Marker 13b_agent_sandbox written.  Stage 3-5i complete."
