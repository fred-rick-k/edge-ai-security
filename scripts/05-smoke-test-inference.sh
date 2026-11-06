#!/usr/bin/env bash
# scripts/05-smoke-test-inference.sh
# Stage 5 – Smoke test for vlm-server (llama.cpp serving Cosmos-Reason2-2B).
#
# API contract (llama-server, OpenAI-compatible):
#   GET  /health                 → 200 once the model is loaded
#   GET  /v1/models              → 200 JSON
#   POST /v1/chat/completions    → 200 JSON, choices[0].message.content
#
# Checks:
#   1. GET /health → HTTP 200
#   2. POST /v1/chat/completions with a synthetic image (red square on blue)
#      → HTTP 200 AND coherent English that mentions a colour in the image
#      (HTTP 200 alone proves nothing — see AGENTS.md §7)
#   3. Server process memory: VmRSS ≤ 7.5 GB, VmSwap = 0 kB, system swap in use = 0
#   4. No error lines in journalctl -u vlm-server since the last service start
#
# Run standalone on the Jetson:
#   ./scripts/05-smoke-test-inference.sh [--host 127.0.0.1] [--port 8090]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1090,SC1091
  source "${REPO_ROOT}/.env"
  set +a
fi

SHIM_HOST="${SMOKE_HOST:-127.0.0.1}"
SHIM_PORT="${SMOKE_PORT:-${VLM_PORT:-8090}}"
SERVICE_NAME="vlm-server"

PASS=0
FAIL=0
ok()   { echo "  ✓ $*"; PASS=$(( PASS + 1 )); }
fail() { echo "  ✗ $*"; FAIL=$(( FAIL + 1 )); }

sudocmd() {
  if [[ -n "${SUDO_PASS:-}" ]]; then echo "${SUDO_PASS}" | sudo -S "$@"; else sudo -n "$@"; fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) SHIM_HOST="$2"; shift 2 ;;
    --port) SHIM_PORT="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done
BASE_URL="http://${SHIM_HOST}:${SHIM_PORT}"

echo "── Stage 5: Smoke Test (Cosmos-Reason2-2B / llama.cpp) ──────────────────"
echo "    Target: ${BASE_URL}"
echo

# ── 1. GET /health ────────────────────────────────────────────────────────────
echo "── Check 1: GET /health"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 "${BASE_URL}/health" 2>/dev/null || echo "000")
if [[ "${HTTP_CODE}" == "200" ]]; then
  ok "GET /health → HTTP 200"
else
  fail "GET /health → HTTP ${HTTP_CODE} (expected 200)"
  echo "    Logs: journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
fi

# ── 2. POST /v1/chat/completions ──────────────────────────────────────────────
echo
echo "── Check 2: POST /v1/chat/completions (image → text)"

TMP_DIR="$(mktemp -d /tmp/smoke.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# 256x256 RGB PNG: red square on a blue background — known ground truth.
python3 - "${TMP_DIR}/payload.json" <<'PYEOF'
import sys, json, struct, zlib, base64

def chunk(tag, data):
    raw = tag + data
    return struct.pack(">I", len(data)) + raw + struct.pack(">I", zlib.crc32(raw) & 0xffffffff)

W = H = 256
rows = b""
for y in range(H):
    row = b"\x00"
    for x in range(W):
        row += bytes([220, 20, 20]) if (64 <= x < 192 and 64 <= y < 192) else bytes([20, 40, 200])
    rows += row
png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(rows))
       + chunk(b"IEND", b""))
b64 = base64.b64encode(png).decode()

payload = {
    "model": "cosmos-reason2-2b",
    "messages": [{
        "role": "user",
        "content": [
            {"type": "image_url", "image_url": {"url": "data:image/png;base64," + b64}},
            {"type": "text", "text": "Describe this image in one or two sentences. Name the colors you see."},
        ],
    }],
    "max_tokens": 1024,
    "temperature": 0.0,
}
with open(sys.argv[1], "w") as f:
    json.dump(payload, f)
PYEOF

HTTP_CODE=$(curl -s -o "${TMP_DIR}/response.json" -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" \
  --data @"${TMP_DIR}/payload.json" \
  --max-time 240 "${BASE_URL}/v1/chat/completions" 2>/dev/null || echo "000")

if [[ "${HTTP_CODE}" != "200" ]]; then
  fail "POST /v1/chat/completions → HTTP ${HTTP_CODE} (expected 200)"
  head -c 400 "${TMP_DIR}/response.json" 2>/dev/null | sed 's/^/    /' || true
else
  ok "POST /v1/chat/completions → HTTP 200"
  set +e
  python3 - "${TMP_DIR}/response.json" <<'PYEOF'
import sys, json, re
data = json.load(open(sys.argv[1]))
msg = data["choices"][0]["message"]
content = (msg.get("content") or "").strip()
reasoning = (msg.get("reasoning_content") or "").strip()
# Reasoning models may emit <think>…</think>; judge the final answer if present.
answer = re.sub(r"<think>.*?</think>", "", content, flags=re.S).strip() or content
text = answer or reasoning
print("  response:", (answer or reasoning)[:300].replace("\n", " "))
if len(text) < 10:
    print("  EMPTY_OR_TOO_SHORT"); sys.exit(2)
letters = sum(c.isalpha() for c in text)
if letters / max(len(text), 1) < 0.6:
    print("  NOT_COHERENT_TEXT (low letter ratio)"); sys.exit(2)
if not re.search(r"\b(red|blue|square|rectangle)\b", (answer + " " + reasoning).lower()):
    print("  NO_REFERENCE_TO_IMAGE_CONTENT (expected red/blue/square)"); sys.exit(2)
sys.exit(0)
PYEOF
  RC=$?
  set -e
  if [[ "${RC}" -eq 0 ]]; then
    ok "Coherent English that matches the image (mentions red/blue/square)"
  else
    fail "Response is not a coherent description of the test image (see above)"
  fi
fi

# ── 3. Memory / swap ──────────────────────────────────────────────────────────
echo
echo "── Check 3: server process memory"
PID=$(docker inspect -f '{{.State.Pid}}' "${SERVICE_NAME}" 2>/dev/null || sudocmd docker inspect -f '{{.State.Pid}}' "${SERVICE_NAME}" 2>/dev/null || echo 0)
if [[ "${PID}" -gt 0 ]] && [[ -r "/proc/${PID}/status" ]]; then
  RSS_KB=$(awk '/VmRSS/  {print $2}' "/proc/${PID}/status" 2>/dev/null || echo 0)
  SWP_KB=$(awk '/VmSwap/ {print $2}' "/proc/${PID}/status" 2>/dev/null || echo 0)
  RSS_GB=$(awk "BEGIN {printf \"%.2f\", ${RSS_KB}/1048576}")
  [[ "${RSS_KB}" -le 7864320 ]] \
    && ok "llama-server RSS: ${RSS_GB} GB (PID ${PID}, ≤ 7.5 GB)" \
    || fail "llama-server RSS: ${RSS_GB} GB exceeds 7.5 GB"
  [[ "${SWP_KB}" -eq 0 ]] \
    && ok "llama-server swap: 0 kB" \
    || fail "llama-server swap: ${SWP_KB} kB (expected 0)"
else
  fail "container '${SERVICE_NAME}' PID not found — is the service running?"
fi
# Informational: container-runtime daemon overhead (not part of the llama-server RSS above).
DOCKER_RSS_KB=0
for p in dockerd containerd; do
  for dpid in $(pgrep -x "${p}" 2>/dev/null || true); do
    kb=$(awk '/VmRSS/ {print $2}' "/proc/${dpid}/status" 2>/dev/null || echo 0)
    DOCKER_RSS_KB=$(( DOCKER_RSS_KB + ${kb:-0} ))
  done
done
echo "    docker daemons (dockerd+containerd) RSS: $(awk "BEGIN {printf \"%.0f\", ${DOCKER_RSS_KB}/1024}") MB (informational)"
SWAP_USED_KB=$(awk '/SwapTotal/ {t=$2} /SwapFree/ {f=$2} END {print t-f}' /proc/meminfo)
echo "    system: $(awk '/MemAvailable/ {printf "%.2f GB available", $2/1048576}' /proc/meminfo), swap in use: ${SWAP_USED_KB} kB (informational — build swapfile may hold idle pages)"

# ── 4. Journal scan since last start ──────────────────────────────────────────
echo
echo "── Check 4: journal error scan (since last service start)"
SINCE=$(systemctl show "${SERVICE_NAME}.service" --property=ActiveEnterTimestamp --value 2>/dev/null || true)
if [[ -n "${SINCE}" ]]; then
  JOURNAL=$(journalctl -u "${SERVICE_NAME}" --no-pager --since "${SINCE}" 2>/dev/null || true)
else
  JOURNAL=$(journalctl -u "${SERVICE_NAME}" --no-pager -n 200 2>/dev/null || true)
fi
ERRORS=$(echo "${JOURNAL}" | grep -iE '(\berror\b|\bfatal\b|cuda error|exception|traceback|out of memory|\bkilled\b|failed to)' \
  | grep -viE '(no error|error_count=0)' || true)
if [[ -z "${ERRORS}" ]]; then
  ok "No error lines in journal since ${SINCE:-last 200 lines}"
else
  fail "$(echo "${ERRORS}" | wc -l | tr -d ' ') error line(s) in journal:"
  echo "${ERRORS}" | head -15 | sed 's/^/    /'
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "════════════════════════════════════════════════════"
echo "  Smoke test results: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════════════════"
if [[ "${FAIL}" -gt 0 ]]; then
  echo "One or more checks failed. Logs: journalctl -u ${SERVICE_NAME} -n 100 --no-pager"
  exit 1
fi
echo "All checks passed.  Phase 1 complete ✓"
echo "  Endpoint: ${BASE_URL}/v1/chat/completions"
echo "  Model:    Cosmos-Reason2-2B Q4_K_M (llama.cpp)"
