#!/usr/bin/env bash
# scripts/04-install-services.sh
# Stage 4 – Install vlm-server.service (llama.cpp container serving
#           Cosmos-Reason2-2B Q4_K_M on :8090, OpenAI-compatible).
#
# Actions:
#   1. Pre-flight: GGUF + projector + container image + NVIDIA docker runtime
#   2. NOPASSWD sudoers rule for sync + drop_caches (used by ExecStartPre)
#   3. Install /usr/local/sbin/vlm-swap-lock.sh (ExecStartPost helper, see below)
#   4. Write /etc/systemd/system/vlm-server.service  (runs as root; the
#      jetson user is not in the docker group)
#   5. Write MemorySwapMax=0 drop-in (limits the docker CLI cgroup only)
#   6. daemon-reload, enable, start; wait for GET /health → 200
#   7. Verify from the KERNEL (cgroup files, /proc), not from `docker inspect`:
#      memory.swap.max == 0, memory.swap.current == 0, VmSwap == 0, and again after
#      two `systemctl daemon-reload`s. The stage ABORTS if any of these is false.
#
# Swap/memory (Session 3-5j2, T-23, all VERIFIED on the device 2026-10-18):
#   - `--memory X --memory-swap X` makes runc write memory.swap.max=0 at container
#     creation (also with --runtime nvidia) ...
#   - ... but the container's systemd scope has MemorySwapMax=infinity in systemd's
#     model, so the next `systemctl daemon-reload` resets it to `max`. The old container
#     ran 5 days through 459 reloads and swapped 7.8 GB. `docker inspect` still showed
#     Memory == MemorySwap, i.e. it is not evidence of the live limit.
#   - `systemctl set-property --runtime <scope> MemorySwapMax=0` survives 3 reloads
#     (probe 3-5j2a section J1). `--cgroup-parent` under a MemorySwapMax=0 slice does
#     NOT (section J2). The helper below applies J1 on every start and fails the unit
#     if the cgroup file does not read 0.
#   - MemorySwapMax=0 on the vlm-server.service unit only limits the `docker` CLI
#     process cgroup, not the container (systemd.resource-control(5)).
#   - --cache-ram 0: llama-server's host-RAM prompt cache defaults to 8192 MiB (the
#     pinned image's --help, build 10373) and was at its cap, evicting ~125 MiB entries
#     about every 2 s; that is the likely size of the ~8 GB that sat in swap
#     (INFERRED; the soak test measures it). The cache is useless here: every camera
#     frame is a different image.
#
# Docs: https://docs.docker.com/engine/containers/resource_constraints/
#       https://docs.kernel.org/admin-guide/cgroup-v2.html            (memory.swap.max)
#       https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html
#       llama-server --help of the pinned image (probe 3-5j2a section G)
#
# Endpoints (llama-server):
#   GET  /health               → 200 {"status":"ok"} once the model is loaded
#   GET  /v1/models
#   POST /v1/chat/completions  (image_url data: URIs supported via --mmproj)
#
# Expects SUDO_PASS env var.
# State marker written by setup-jetson.sh: .setup-state/08_services

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1090,SC1091
  source "${REPO_ROOT}/.env"
  set +a
fi

MODELS_DIR="${REPO_ROOT}/models/cosmos-reason2"
GGUF_FILE="Cosmos-Reason2-2B-Q4_K_M.gguf"
MMPROJ_FILE="mmproj-Cosmos-Reason2-2B-F16.gguf"
CONTAINER_IMAGE="ghcr.io/nvidia-ai-iot/llama_cpp:latest-jetson-orin"

SERVICE_NAME="vlm-server"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
DROPIN_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"
DROPIN_FILE="${DROPIN_DIR}/10-no-swap.conf"
SWAP_LOCK="/usr/local/sbin/vlm-swap-lock.sh"
SHIM_PORT="${VLM_PORT:-8090}"

# llama-server tuning (Orin Nano Super 8 GB; weights ≈ 2.1 GB with projector)
CTX_SIZE=4096        # image tokens + prompt + reasoning + answer
MEM_LIMIT="5g"       # hard ceiling for the container; swap is forced to 0 by ${SWAP_LOCK}
IMAGE_MIN_TOKENS=1024 # was hand-added to the live unit; the device wins (AGENTS.md §4)
CACHE_RAM_MIB=0      # llama-server --cache-ram: 0 = prompt cache disabled

sudocmd() { echo "${SUDO_PASS}" | sudo -S "$@"; }

echo "── Stage 4: Install vlm-server systemd service (llama.cpp) ───────────"

# ── 1. Pre-flight ─────────────────────────────────────────────────────────────
for f in "${GGUF_FILE}" "${MMPROJ_FILE}"; do
  if [[ ! -s "${MODELS_DIR}/${f}" ]]; then
    echo "ERROR: ${MODELS_DIR}/${f} missing — run Stage 3 first."
    exit 1
  fi
done
if ! sudocmd docker image inspect "${CONTAINER_IMAGE}" >/dev/null 2>&1; then
  echo "ERROR: container image ${CONTAINER_IMAGE} not present — run Stage 3 first."
  exit 1
fi
# Capture first: `docker info | grep -q` under pipefail fails with SIGPIPE (141)
# even when the runtime is present.
DOCKER_RUNTIMES="$(sudocmd docker info --format '{{json .Runtimes}}' 2>/dev/null || true)"
if ! grep -qi 'nvidia' <<<"${DOCKER_RUNTIMES}"; then
  echo "    docker runtimes reported: ${DOCKER_RUNTIMES:-<none>}"
  echo "ERROR: Docker has no NVIDIA runtime."
  echo "       Run: sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
  exit 1
fi
echo "    Model, projector, container image, NVIDIA runtime: OK"

# The image tag is `latest-...`: a re-pull can change llama-server's flags (Session 7-2d: the 2026-10-23 image
# rejects --no-mmap with "invalid argument", which put the unit into a restart loop). Check the flag we use
# against THIS image's own --help before writing the unit.
LS_HELP="$(sudocmd docker run --rm --runtime nvidia --entrypoint llama-server "${CONTAINER_IMAGE}" --help 2>&1 || true)"
if ! grep -q -- '--load-mode' <<<"${LS_HELP}"; then
  echo "ERROR: llama-server in ${CONTAINER_IMAGE} does not list --load-mode in its --help."
  echo "       Check the flags with: docker run --rm --runtime nvidia --entrypoint llama-server ${CONTAINER_IMAGE} --help"
  exit 1
fi
echo "    llama-server --help lists --load-mode: OK"

# ── 2. sudoers: drop_caches without password (ExecStartPre + smoke test) ─────
SUDOERS_TMP="$(mktemp /tmp/vlm-sudoers.XXXXXX)"
cat > "${SUDOERS_TMP}" <<'SUDOERS'
# Allow jetson user to drop page cache for inference headroom (non-destructive).
jetson ALL=(root) NOPASSWD: /bin/sync, /sbin/sysctl -w vm.drop_caches=3
SUDOERS
sudocmd visudo -c -f "${SUDOERS_TMP}" >/dev/null 2>&1 \
  && sudocmd cp "${SUDOERS_TMP}" /etc/sudoers.d/vlm-dropcaches \
  && sudocmd chmod 440 /etc/sudoers.d/vlm-dropcaches \
  && echo "    NOPASSWD sudoers rule installed for sync + sysctl drop_caches."
rm -f "${SUDOERS_TMP}"

# ── 3. swap-lock helper (ExecStartPost) ───────────────────────────────────────
echo "--> Installing ${SWAP_LOCK}..."
LOCK_TMP="$(mktemp /tmp/vlm-swap-lock.XXXXXX)"
cat > "${LOCK_TMP}" <<'LOCK'
#!/bin/bash
# vlm-swap-lock.sh – ExecStartPost of vlm-server.service (installed by scripts/04).
# Makes the container's swap limit survive `systemctl daemon-reload` (T-23).
# Fails (non-zero) if memory.swap.max does not read 0 afterwards => the unit fails.
set -euo pipefail
NAME="${1:-vlm-server}"
fail() { echo "vlm-swap-lock: FAIL: $*" >&2; exit 1; }

for _ in $(seq 1 90); do
  [[ "$(/usr/bin/docker inspect -f '{{.State.Running}}' "${NAME}" 2>/dev/null || true)" == "true" ]] && break
  sleep 1
done
PID="$(/usr/bin/docker inspect -f '{{.State.Pid}}' "${NAME}" 2>/dev/null || true)"
[[ "${PID}" =~ ^[1-9][0-9]*$ ]] || fail "container ${NAME} not running after 90 s"
REL="$(awk -F: '$1=="0" {print $3}' "/proc/${PID}/cgroup")"
SCOPE="$(basename "${REL}")"
[[ "${SCOPE}" == docker-*.scope ]] || fail "unexpected cgroup '${REL}' (not a docker systemd scope)"
CG="/sys/fs/cgroup${REL}"

/usr/bin/systemctl set-property --runtime "${SCOPE}" MemorySwapMax=0 || fail "systemctl set-property failed"
SWAP_MAX="$(cat "${CG}/memory.swap.max")"
MEM_MAX="$(cat "${CG}/memory.max")"
[[ "${SWAP_MAX}" == "0" ]] || fail "${CG}/memory.swap.max = ${SWAP_MAX} (expected 0)"
[[ "${MEM_MAX}" != "max" ]] || fail "${CG}/memory.max = max (no RAM cap)"
echo "vlm-swap-lock: ${SCOPE}: memory.swap.max=${SWAP_MAX} memory.max=${MEM_MAX}"
LOCK
sudocmd cp "${LOCK_TMP}" "${SWAP_LOCK}"
sudocmd chown root:root "${SWAP_LOCK}"
sudocmd chmod 755 "${SWAP_LOCK}"
rm -f "${LOCK_TMP}"
bash -n "${SWAP_LOCK}" || { echo "ERROR: ${SWAP_LOCK} has a syntax error"; exit 1; }

# ── 4. Service unit ───────────────────────────────────────────────────────────
echo "--> Writing ${SERVICE_FILE}..."
SERVICE_TMP="$(mktemp /tmp/vlm-server-unit.XXXXXX)"
cat > "${SERVICE_TMP}" <<UNIT
[Unit]
Description=Cosmos-Reason2-2B VLM (llama.cpp container, OpenAI-compatible)
Documentation=https://www.jetson-ai-lab.com/models/cosmos-reason2-2b/
After=network.target docker.service jetson-clocks.service nvpmodel.service
Requires=docker.service
Wants=jetson-clocks.service

[Service]
Type=simple
Environment=HOME=/root
ExecStartPre=-/usr/bin/docker rm -f ${SERVICE_NAME}
ExecStartPre=/bin/sync
ExecStartPre=/sbin/sysctl -w vm.drop_caches=3
ExecStart=/usr/bin/docker run --rm --name ${SERVICE_NAME} \\
  --runtime nvidia --network host \\
  --memory ${MEM_LIMIT} --memory-swap ${MEM_LIMIT} \\
  -v ${MODELS_DIR}:/models:ro \\
  ${CONTAINER_IMAGE} \\
  llama-server \\
    -m /models/${GGUF_FILE} \\
    --mmproj /models/${MMPROJ_FILE} \\
    --host 0.0.0.0 --port ${SHIM_PORT} \\
    -ngl 99 -c ${CTX_SIZE} -np 1 \\
    --image-min-tokens ${IMAGE_MIN_TOKENS} \\
    --cache-ram ${CACHE_RAM_MIB} \\
    --load-mode none \\
    --alias cosmos-reason2-2b
ExecStartPost=${SWAP_LOCK} ${SERVICE_NAME}
ExecStop=/usr/bin/docker stop -t 20 ${SERVICE_NAME}
Restart=on-failure
RestartSec=10s
TimeoutStartSec=300
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
UNIT
sudocmd cp "${SERVICE_TMP}" "${SERVICE_FILE}"
sudocmd chmod 644 "${SERVICE_FILE}"
rm -f "${SERVICE_TMP}"

# ── 5. MemorySwapMax=0 drop-in ────────────────────────────────────────────────
echo "--> Writing MemorySwapMax=0 drop-in at ${DROPIN_FILE}..."
sudocmd mkdir -p "${DROPIN_DIR}"
DROPIN_TMP="$(mktemp /tmp/vlm-dropin.XXXXXX)"
cat > "${DROPIN_TMP}" <<'DROPIN'
# 10-no-swap.conf – limits the swap of the unit's OWN cgroup, i.e. the `docker` CLI process.
# It does NOT constrain the container (that lives in docker-<id>.scope); the container's
# limit is set by --memory-swap at creation and re-asserted by vlm-swap-lock.sh
# (ExecStartPost), because `systemctl daemon-reload` resets the former (T-23, verified).
[Service]
MemorySwapMax=0
DROPIN
sudocmd cp "${DROPIN_TMP}" "${DROPIN_FILE}"
sudocmd chmod 644 "${DROPIN_FILE}"
rm -f "${DROPIN_TMP}"

# ── 6. Reload, enable, start, wait for /health ───────────────────────────────
echo "--> Reloading systemd and enabling ${SERVICE_NAME}.service..."
sudocmd systemctl daemon-reload
sudocmd systemctl enable "${SERVICE_NAME}.service"

echo "--> Starting ${SERVICE_NAME}.service..."
sudocmd systemctl restart "${SERVICE_NAME}.service"

echo "--> Waiting for model load (up to 180 s)..."
READY=false
for i in $(seq 1 36); do
  sleep 5
  CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    "http://127.0.0.1:${SHIM_PORT}/health" 2>/dev/null || echo "000")
  if [[ "${CODE}" == "200" ]]; then
    READY=true
    echo "    /health → 200 OK (after $((i * 5)) s)"
    break
  fi
  echo "    ... waiting (${i}/36, last HTTP ${CODE})"
done

if [[ "${READY}" != "true" ]]; then
  echo
  echo "ERROR: ${SERVICE_NAME} did not become ready within 180 s."
  echo "       Logs: journalctl -u ${SERVICE_NAME} -n 80 --no-pager"
  echo "       If the log shows a CUDA/driver error, the container (built for"
  echo "       JetPack 6 / CUDA 12) may not run on this JetPack 7 / CUDA 13 host."
  sudocmd journalctl -u "${SERVICE_NAME}" -n 40 --no-pager || true
  exit 1
fi

sudocmd systemctl status "${SERVICE_NAME}.service" --no-pager -l || true

# ── 7. Verify the limit from the kernel (not from docker inspect) ─────────────
echo "--> Verifying the swap limit in /sys/fs/cgroup and /proc (stage aborts on failure)..."
VFAIL=0
vfail() { echo "    FAIL: $*"; VFAIL=1; }

C_PID="$(sudocmd docker inspect -f '{{.State.Pid}}' "${SERVICE_NAME}" 2>/dev/null || true)"
if ! [[ "${C_PID}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: cannot read the PID of container ${SERVICE_NAME}"; exit 1
fi
C_REL="$(awk -F: '$1=="0" {print $3}' "/proc/${C_PID}/cgroup")"
C_CG="/sys/fs/cgroup${C_REL}"
echo "    container pid ${C_PID}, cgroup ${C_REL}"

read_cg() { sudocmd cat "${C_CG}/$1" 2>/dev/null | tr -d '[:space:]'; }

check_swap() {   # $1 = label
  local smax scur mmax vmswap
  smax="$(read_cg memory.swap.max)"; scur="$(read_cg memory.swap.current)"; mmax="$(read_cg memory.max)"
  vmswap="$(awk '/^VmSwap:/ {print $2}' "/proc/${C_PID}/status" 2>/dev/null || echo '')"
  echo "    [$1] memory.max=${mmax} memory.swap.max=${smax} memory.swap.current=${scur} VmSwap=${vmswap:-?} kB"
  [[ "${smax}" == "0" ]]  || vfail "[$1] memory.swap.max is '${smax}', expected 0"
  [[ "${scur}" == "0" ]]  || vfail "[$1] memory.swap.current is '${scur}', expected 0"
  [[ "${vmswap}" == "0" ]] || vfail "[$1] VmSwap is '${vmswap}' kB, expected 0"
  [[ "${mmax}" != "max" && -n "${mmax}" ]] || vfail "[$1] memory.max is '${mmax}' (no RAM cap)"
}

check_swap "after start"
echo "    running 2 x systemctl daemon-reload (the thing that reset the limit before)..."
sudocmd systemctl daemon-reload
sudocmd systemctl daemon-reload
check_swap "after 2 reloads"

# the flags that are supposed to be live
RUN_CMD="$(sudocmd docker inspect -f '{{join .Config.Cmd " "}}' "${SERVICE_NAME}" 2>/dev/null || true)"
echo "    llama-server cmd: ${RUN_CMD}"
grep -q -- "--cache-ram ${CACHE_RAM_MIB}" <<<"${RUN_CMD}" || vfail "--cache-ram ${CACHE_RAM_MIB} not in the running command"
grep -q -- "--image-min-tokens ${IMAGE_MIN_TOKENS}" <<<"${RUN_CMD}" || vfail "--image-min-tokens ${IMAGE_MIN_TOKENS} not in the running command"

if [[ "${VFAIL}" -ne 0 ]]; then
  echo
  echo "ERROR: ${SERVICE_NAME} is running but the memory guarantee is NOT in place (see FAIL lines)."
  exit 1
fi

echo
echo "── Stage 4 complete ────────────────────────────────────────────────────"
echo "    vlm-server listening on http://0.0.0.0:${SHIM_PORT}"
echo "    Endpoints: GET /health  GET /v1/models  POST /v1/chat/completions"
echo "    Memory: container capped at ${MEM_LIMIT}; memory.swap.max=0 verified in the cgroup, also after reloads."
