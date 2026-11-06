#!/usr/bin/env bash
# scripts/07-test-openshell-policy.sh
# Phase 3 Stage 3-2 (openshell-test) – REAL enforcement test of the running `camera-agent` sandbox.
# Rewritten in Session 3-5j. The previous version (Session 3-2) simulated the denial and wrote its own
# "NETWORK_EGRESS_DENIED" line to /var/log/openshell/audit.log; that was retracted 2026-10-17 (CHANGELOG).
#
# Nothing here is simulated and NOTHING in this script writes to any audit log. Every PASS is either
#   (a) the exit status / HTTP code of a request made from INSIDE the running sandbox, or
#   (b) a line the OpenShell supervisor itself logged (`openshell logs camera-agent --source sandbox`).
# The only file this script writes is its own transcript (/tmp/openshell-policy-test.log).
#
# Docs (v0.1.4): https://docs.nvidia.com/openshell/latest/how-it-works/sandboxes/inspect.md
#                https://docs.nvidia.com/openshell/latest/how-it-works/sandboxes/create.md
#
# Precondition: sandbox `camera-agent` exists and is Ready (stage 3-5i, marker 13b_agent_sandbox).
#
# Checks:
#   1. Sandbox Ready; effective policy contains _provider_edge_ingest and _provider_cosmos_vlm.
#   2. ALLOWED ingest: GET http://jetson.localdomain:8095/frame.jpg with the X-Edge-Key taken from the
#      sandbox's own INGEST_KEY env -> HTTP 200 + JPEG magic bytes; the env value is an opaque
#      `openshell:resolve:env:` placeholder (not the real key).
#   3. ALLOWED VLM: GET /health and POST /v1/chat/completions (text only) on jetson.localdomain:8090 -> HTTP 200.
#   4. DENIED connections from inside the sandbox: a unique never-allowed hostname on :443, and an allowed
#      host on the wrong port (jetson.localdomain:22). Each must (i) fail in the client and (ii) produce a NEW
#      `NET:OPEN ... DENIED` line in `openshell logs camera-agent --source sandbox` written by the supervisor.
#   5. Memory (informational + hard limits): llama-server container VmRSS <= 5 GB, VmSwap = 0.
#
# Usage: ./scripts/bootstrap-jetson.sh <jetson-ip> --only-stage 3-2

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1090,SC1091
  source "${REPO_ROOT}/.env"
  set +a
fi

NAME="camera-agent"
LOG="/tmp/openshell-policy-test.log"
JETSON_HOSTNAME="${JETSON_HOSTNAME:-jetson.localdomain}"
TE_PORT="${TRUSTED_EDGE_PORT:-8095}"
VLM_PORT="${VLM_PORT:-8090}"
FAIL=0

: > "${LOG}"
say()  { echo "$*" | tee -a "${LOG}"; }
pass() { say "  [PASS] $*"; }
fail() { say "  [FAIL] $*"; FAIL=1; }
info() { say "  [INFO] $*"; }

sbx() { openshell sandbox exec -n "${NAME}" --no-tty --no-login-shell --timeout 150 -- "$@" < /dev/null 2>&1; }

say "── Phase 3 Stage 3-2: real policy test of sandbox '${NAME}' ───────────────"

# ── 1. sandbox state + effective policy ──────────────────────────────────────
PHASE="$(openshell sandbox list 2>&1 | awk -v n="${NAME}" '$1==n {print $NF}')"
if [[ "${PHASE}" != "Ready" ]]; then
  say "ERROR: sandbox ${NAME} is not Ready (phase='${PHASE:-absent}'). Run stage 3-5i first. Nothing was tested."
  exit 1
fi
pass "sandbox ${NAME} is Ready"

POL="$(openshell policy get "${NAME}" --full 2>&1)"
echo "${POL}" >> "${LOG}"
for rule in _provider_edge_ingest _provider_cosmos_vlm; do
  if grep -q "${rule}" <<<"${POL}"; then pass "effective policy contains ${rule}"
  else fail "effective policy is missing ${rule}"; fi
done
grep -q "hard_requirement" <<<"${POL}" && pass "landlock.compatibility = hard_requirement" \
  || fail "hard_requirement not in effective policy"

WL="$(docker ps --filter "label=openshell.ai/sandbox-name=${NAME}" --filter "label=openshell.ai/isolation-role=sandbox" --format '{{.Names}}' | head -1)"
if [[ -n "${WL}" ]]; then
  info "workload container ${WL}, RestartCount=$(docker inspect -f '{{.RestartCount}}' "${WL}" 2>/dev/null)"
else
  info "workload container not found via labels (informational)"
fi

# ── 2. ALLOWED ingest request, key = the sandbox's own placeholder ───────────
INGEST_PROBE='import os,sys,urllib.request
k=os.environ.get("INGEST_KEY","")
print("KEYENV", k[:22] if k.startswith("openshell:resolve:env:") else "NOT-A-PLACEHOLDER(len=%d)" % len(k))
req=urllib.request.Request("http://'"${JETSON_HOSTNAME}:${TE_PORT}"'/frame.jpg",headers={"X-Edge-Key":k})
try:
    r=urllib.request.urlopen(req,timeout=20)
    b=r.read()
    print("HTTP",r.status,"bytes",len(b),"jpeg",b[:2]==b"\xff\xd8")
except Exception as e:
    print("ERR",type(e).__name__,str(e)[:200])'
say "--> ALLOWED probe: GET http://${JETSON_HOSTNAME}:${TE_PORT}/frame.jpg (from inside ${NAME})"
OUT="$(sbx /usr/bin/python3.12 -c "${INGEST_PROBE}")"
say "$(sed 's/^/    result: /' <<<"${OUT}")"
grep -q "^KEYENV openshell:resolve:env:" <<<"${OUT}" \
  && pass "INGEST_KEY in the sandbox env is an opaque openshell:resolve:env: placeholder" \
  || fail "INGEST_KEY in the sandbox env is not a placeholder"
if grep -qE "^HTTP 200 bytes [0-9]+ jpeg True" <<<"${OUT}"; then
  pass "ingest GET /frame.jpg -> HTTP 200 with a JPEG (supervisor injected the real key)"
else
  fail "ingest GET /frame.jpg did not return a 200 JPEG"
fi

# ── 3. ALLOWED VLM requests ──────────────────────────────────────────────────
VLM_PROBE='import json,sys,urllib.request
base="http://'"${JETSON_HOSTNAME}:${VLM_PORT}"'"
try:
    r=urllib.request.urlopen(base+"/health",timeout=20)
    print("HEALTH",r.status)
    body=json.dumps({"model":"cosmos-reason2-2b","messages":[{"role":"user","content":"Reply with OK."}],"max_tokens":16,"temperature":0}).encode()
    req=urllib.request.Request(base+"/v1/chat/completions",data=body,headers={"Content-Type":"application/json"},method="POST")
    r=urllib.request.urlopen(req,timeout=90)
    d=json.loads(r.read())
    m=d["choices"][0]["message"]
    print("CHAT",r.status,"keys",sorted(m.keys()))
except Exception as e:
    print("ERR",type(e).__name__,str(e)[:200])'
say "--> ALLOWED probe: GET /health and POST /v1/chat/completions on ${JETSON_HOSTNAME}:${VLM_PORT}"
OUT="$(sbx /usr/bin/python3.12 -c "${VLM_PROBE}")"
say "$(sed 's/^/    result: /' <<<"${OUT}")"
grep -q "^HEALTH 200" <<<"${OUT}" && pass "VLM GET /health -> HTTP 200 via cosmos-vlm" || fail "VLM /health not 200"
grep -q "^CHAT 200" <<<"${OUT}"   && pass "VLM POST /v1/chat/completions -> HTTP 200 via cosmos-vlm" || fail "VLM chat request not 200"

# ── 4. DENIED connections + the supervisor's own DENIED lines ────────────────
CONNECT_PROBE='import sys,urllib.request
try:
    r=urllib.request.urlopen(sys.argv[1],timeout=15)
    print("HTTP",r.status)
except Exception as e:
    print("ERR",type(e).__name__,str(e)[:160])'
DENY_HOST="probe-$$-$(date +%s).example.com"
count_denied() { openshell logs "${NAME}" --source sandbox -n 2000 2>&1 | grep -cE "$1"; }

BEFORE_22="$(count_denied 'NET:OPEN.*DENIED.*:22 \[reason:')"
say "--> DENIED probe 1: https://${DENY_HOST}/ (hostname never in any policy)"
OUT1="$(sbx /usr/bin/python3.12 -c "${CONNECT_PROBE}" "https://${DENY_HOST}/")"
say "    result: ${OUT1}"
grep -q "^HTTP " <<<"${OUT1}" && fail "${DENY_HOST} was REACHABLE" || pass "client could not reach ${DENY_HOST}"

say "--> DENIED probe 2: wrong port on an allowed host (http://${JETSON_HOSTNAME}:22/)"
OUT2="$(sbx /usr/bin/python3.12 -c "${CONNECT_PROBE}" "http://${JETSON_HOSTNAME}:22/")"
say "    result: ${OUT2}"
grep -q "^HTTP " <<<"${OUT2}" && fail "${JETSON_HOSTNAME}:22 was reachable" || pass "client could not reach ${JETSON_HOSTNAME}:22"

sleep 3
SB_LOG="$(openshell logs "${NAME}" --source sandbox -n 2000 2>&1)"
echo "${SB_LOG}" >> "${LOG}"
say "--> Supervisor lines produced by these probes (openshell logs ${NAME} --source sandbox):"
grep -E "${DENY_HOST}|NET:OPEN.*DENIED.*:22 \[reason:" <<<"${SB_LOG}" | tail -6 | sed 's/^/    | /' | tee -a "${LOG}"
DENY1="$(grep -E "${DENY_HOST}" <<<"${SB_LOG}" | grep -E "DENIED|denied" | head -1)"
if [[ -n "${DENY1}" ]]; then pass "supervisor logged DENIED for ${DENY_HOST}: $(sed 's/.*\(NET:OPEN\)/\1/' <<<"${DENY1}" | cut -c1-200)"
else fail "no supervisor DENIED line for ${DENY_HOST}"; fi
AFTER_22="$(count_denied 'NET:OPEN.*DENIED.*:22 \[reason:')"
if [[ "${AFTER_22}" -gt "${BEFORE_22}" ]]; then
  pass "supervisor logged a NEW DENIED line for the :22 connect (${BEFORE_22} -> ${AFTER_22})"
else
  fail "no new supervisor DENIED line for the :22 connect (${BEFORE_22} -> ${AFTER_22})"
fi
# Informational only: the exact log format of an ALLOWED L7 connection is not asserted.
info "ALLOWED-side supervisor lines (not asserted, format unverified):"
grep -E "ALLOWED.*(8095|8090)" <<<"${SB_LOG}" | tail -3 | sed 's/^/    | /' | tee -a "${LOG}"

# ── 5. VLM server memory (hard limits from AGENTS.md section 7) ──────────────
PID="$(docker inspect -f '{{.State.Pid}}' vlm-server 2>/dev/null || echo 0)"
if [[ "${PID}" -gt 0 && -r "/proc/${PID}/status" ]]; then
  RSS_KB="$(awk '/VmRSS/ {print $2}' "/proc/${PID}/status")"
  SWP_KB="$(awk '/VmSwap/ {print $2}' "/proc/${PID}/status")"
  say "    vlm-server VmRSS=$(awk "BEGIN{printf \"%.2f\", ${RSS_KB}/1048576}") GB VmSwap=${SWP_KB} kB"
  [[ "${RSS_KB}" -le 5242880 ]] && pass "vlm-server VmRSS within the 5 GB container cap" || fail "vlm-server VmRSS above 5 GB"
  [[ "${SWP_KB}" -eq 0 ]] && pass "vlm-server VmSwap = 0" || fail "vlm-server uses swap (${SWP_KB} kB)"
else
  fail "cannot read vlm-server container PID/status (docker inspect returned '${PID}')"
fi

# ── result ───────────────────────────────────────────────────────────────────
if [[ ${FAIL} -ne 0 ]]; then
  say "ERROR: OpenShell policy test FAILED. Transcript: ${LOG}"
  exit 1
fi
say "==> OpenShell policy test PASSED against the running sandbox '${NAME}'. Transcript: ${LOG}"
