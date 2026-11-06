#!/usr/bin/env bash
# scripts/setup-jetson.sh
# Jetson-side idempotent master runner.
#
# Runs on the Jetson itself (invoked by bootstrap-jetson.sh over SSH, or
# directly: ~/edge-device-demo/scripts/setup-jetson.sh).
#
# Usage:
#   setup-jetson.sh                  # run all pending stages in dependency order (run_default_order)
#   setup-jetson.sh --phase 2        # run all pending stages for Phase 2
#   setup-jetson.sh --only-stage 2-1 # run ONLY Phase 2 Stage 1 (WebUI install)
#   setup-jetson.sh --only-stage webui
#
# State markers live in ~/edge-device-demo/.setup-state/.
#
# Phase & Stage Mapping:
#   Phase 1 (VLM Server on :8090):
#     1-1 (1, prep)        → 01_prep          env prep, headless mode, clocks, swap
#     1-2 (3, model)       → 03_*             Cosmos-Reason2-2B GGUF + llama.cpp container
#     1-3 (4, vlm)         → 08_services      vlm-server.service install
#     1-4 (5, vlm-smoke)   → (no marker)      inference smoke test
#   Phase 2 (Live VLM WebUI on :8443):
#     2-1 (webui)          → 09_webui         live-vlm-webui.service install
#     2-2 (webui-smoke)    → (no marker)      WebUI verification & smoke test
#   Phase 3 (OpenShell Sandbox):
#     3-1 (openshell)      → 10_openshell     OpenShell supervisor install + policy
#     3-2 (openshell-test) → (no marker)      REAL policy test of the running camera-agent sandbox
#                                           (needs stage 3-5i first; always runs; writes no audit log)
#     3-3 (openshell-ui)   → (no new marker)  OpenShell demo UI card (re-run
#                                           stage 2-1 / 09_webui to redeploy)
#     3-4a (sandbox-smoke) → (no marker)      REAL sandbox smoke test: throwaway sandbox,
#                                           default policy, Landlock log line (always runs)
#     3-4b (agent-sandbox-test) → (no marker) build agent image, sandbox under agent/policy.yaml,
#                                           allowed + denied egress (always runs)
#     3-5a (provider-probe) → (no marker)     MEASURE the OpenShell provider route for the
#                                           Vault token (X-Vault-Token header injection)
#     3-5c (provider-update-probe) → (no marker) does `provider update` reach a RUNNING sandbox process?
#     3-5d (gateway-vault-driver-probe) → (no marker) probe the gateway `vault` credential driver
#                                           (KV mount, token_file auth, CA matrix); restores gateway.toml
#     3-5g (trusted-edge)  → 13_trusted_edge   trusted-edge.service: the only host process that
#                                           touches camera, DEK and database (GET /frame.jpg, POST /events)
#     3-5h (gateway-vault-driver) → 13a_gateway_vault_driver  permanent Vault driver + providers
#                                           edge-ingest and cosmos-vlm; handoff file deleted
#     3-5i (agent-sandbox)        → 13b_agent_sandbox          persistent camera-agent sandbox,
#                                           slim agent.py (requests only), live gate
#     3-5j (camera-credential)    → 14_camera_credential       retires config/camera.env: vault-agent
#                                           template -> tmpfs -> LoadCredential= -> WebUI
#     3-5j2a (vlm-memory-probe)   → (no marker)      READ-ONLY vlm-server memory/swap measurement
#     3-5j2b (wifi-off)           → (no marker)      Wi-Fi radio off + autoconnect off, verified (scripts/19)
#     3-5j2c (ingest-key-resync)  → (no marker)      provider edge-ingest <- key trusted-edge accepts (dev/20)
#                                           (cgroup files, kernel swap accounting, throwaway containers)
#   Phase 5 (End-to-End Integration):
#     5-1 (tpm-agent)         → 11_tpm_agent            vault-agent (edge role, mode 0640 root:edge-ingest)
#     5-1b (tpm-gateway-agent) → 11b_tpm_gateway_agent   vault-agent-gateway (gateway role, mode 0640 root:jetson)
#     5-2 (agent-pipeline)    → 12_agent_pipeline       Transit datakey + dynamic DB creds + agent deps
#     5-3b (vault-widgets)    → 15_vault_widgets        Tab-1 Vault widgets: identity, Rotate Secret Now, payload decrypt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${REPO_ROOT}/.setup-state"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1090,SC1091
  source "${REPO_ROOT}/.env"
  set +a
fi

mkdir -p "${STATE_DIR}"

# ── end-of-run summary (Session 7-2e) ─────────────────────────────────────────
# Every stage that starts is recorded RUN-OK (script exited 0), SKIP (marker present) or FAIL (script
# exited non-zero: set -e aborts, the EXIT trap prints the table). In the default order, stages that were
# never reached are listed as "not run" - never as PASS. "RUN-OK" means the stage script exited 0; what
# the script checked is in its own output.
STAGE_LOG=()
CURRENT_STAGE=""
DEFAULT_ORDER_LABELS=()   # filled by run_default_order
record_stage() { STAGE_LOG+=("$1|$2"); }
print_stage_summary() {
  local rc="$1" entry label status seen l
  [[ ${#STAGE_LOG[@]} -eq 0 && -z "${CURRENT_STAGE}" ]] && return 0
  [[ -n "${CURRENT_STAGE}" ]] && record_stage "${CURRENT_STAGE}" "FAIL"
  echo
  echo "════════════ stage summary (exit code ${rc}) ════════════"
  for entry in "${STAGE_LOG[@]}"; do
    label="${entry%%|*}"; status="${entry##*|}"
    printf '  %-28s %s\n' "${label}" "${status}"
  done
  for l in "${DEFAULT_ORDER_LABELS[@]:-}"; do
    [[ -z "${l}" ]] && continue
    seen=false
    for entry in "${STAGE_LOG[@]}"; do [[ "${entry%%|*}" == "${l}" ]] && seen=true; done
    ${seen} || printf '  %-28s %s\n' "${l}" "not run"
  done
  echo "══════════════════════════════════════════════════════"
}
on_exit() { local rc=$?; print_stage_summary "${rc}"; exit "${rc}"; }
trap on_exit EXIT

# ── helper: stage gate ────────────────────────────────────────────────────────
run_stage() {
  local marker="$1"
  shift
  local marker_file="${STATE_DIR}/${marker}"

  if [[ -f "${marker_file}" ]]; then
    echo "==> [SKIP] Stage ${marker} already complete (marker present)."
    record_stage "${marker}" "SKIP"
    return 0
  fi

  echo
  echo "════════════════════════════════════════════════════"
  echo "==> [RUN ] Stage ${marker} ($*)"
  echo "════════════════════════════════════════════════════"

  local script="$1"
  shift
  CURRENT_STAGE="${marker}"
  bash "${REPO_ROOT}/scripts/${script}" "$@"
  CURRENT_STAGE=""

  touch "${marker_file}"
  record_stage "${marker}" "RUN-OK"
  echo "==> [DONE] Stage ${marker} – marker written."
}

# Stages without a marker (always run): run_always <label> <path-of-script-under-repo> [args]
run_always() {
  local label="$1" script="$2"
  shift 2
  CURRENT_STAGE="${label}"
  bash "${REPO_ROOT}/${script}" "$@"
  CURRENT_STAGE=""
  record_stage "${label}" "RUN-OK"
}

# ── parse args ────────────────────────────────────────────────────────────────
ONLY_STAGE=""
PHASE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)         PHASE="$2" ; shift 2 ;;
    --phase=*)       PHASE="${1#--phase=}" ; shift ;;
    --only-stage)    ONLY_STAGE="$2" ; shift 2 ;;
    --only-stage=*)  ONLY_STAGE="${1#--only-stage=}" ; shift ;;
    *)               echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── sudo password ─────────────────────────────────────────────────────────────
if [[ -z "${SUDO_PASS:-}" ]]; then
  echo "This setup requires sudo for system-level operations."
  read -rsp "Jetson sudo password: " SUDO_PASS
  echo
  export SUDO_PASS
fi
echo "${SUDO_PASS}" | sudo -S true 2>/dev/null \
  || { echo "ERROR: sudo password invalid."; exit 1; }
echo "--> sudo credentials verified."

# ── stage runners ─────────────────────────────────────────────────────────────
# Phase 1
run_stage_1_1() {
  run_stage "01_prep" "01-jetson-prep.sh"
}

run_stage_1_2() {
  echo
  echo "════════════════════════════════════════════════════"
  echo "==> [RUN ] Stage 1-2 – Cosmos-Reason2-2B GGUF + llama.cpp container"
  echo "════════════════════════════════════════════════════"
  run_always "1-2 (no marker)" scripts/03-download-model.sh
}

run_stage_1_3() {
  run_stage "08_services" "04-install-services.sh"
}

run_stage_1_4() {
  echo
  echo "════════════════════════════════════════════════════"
  echo "==> [RUN ] Stage 1-4 – Smoke test (always runs)"
  echo "════════════════════════════════════════════════════"
  run_always "1-4 (no marker)" scripts/05-smoke-test-inference.sh
}

# Phase 2
run_stage_2_1() {
  run_stage "09_webui" "09-install-webui.sh"
}

run_stage_2_2() {
  echo
  echo "════════════════════════════════════════════════════"
  echo "==> [RUN ] Stage 2-2 – WebUI Smoke test (always runs)"
  echo "════════════════════════════════════════════════════"
  run_always "2-2 (no marker)" scripts/10-smoke-test-webui.sh
}

# Phase 3
run_stage_3_1() {
  run_stage "10_openshell" "06-install-openshell.sh"
}

run_stage_3_2() {
  echo
  echo "════════════════════════════════════════════════════"
  echo "==> [RUN ] Stage 3-2 – real policy test of the running camera-agent sandbox (always runs)"
  echo "════════════════════════════════════════════════════"
  run_always "3-2 (no marker)" scripts/07-test-openshell-policy.sh
}

run_stage_3_4a() {
  echo
  echo "════════════════════════════════════════════════════"
  echo "==> [RUN ] Stage 3-4a – OpenShell sandbox smoke test (always runs)"
  echo "════════════════════════════════════════════════════"
  bash "${REPO_ROOT}/dev/13a-sandbox-smoke.sh"
}

run_stage_3_4b() {
  echo
  echo "════════════════════════════════════════════════════"
  echo "==> [RUN ] Stage 3-4b – agent sandbox test (always runs)"
  echo "════════════════════════════════════════════════════"
  bash "${REPO_ROOT}/dev/13b-agent-sandbox-test.sh"
}

run_stage_3_5a() {
  echo
  echo "════════════════════════════════════════════════════"
  echo "==> [RUN ] Stage 3-5a – provider route probe (always runs)"
  echo "════════════════════════════════════════════════════"
  bash "${REPO_ROOT}/dev/14a-provider-probe.sh"
}

run_stage_3_5c() {
  echo
  echo "════════════════════════════════════════════════════"
  echo "==> [RUN ] Stage 3-5c – provider update reaches a running process? (always runs)"
  echo "════════════════════════════════════════════════════"
  bash "${REPO_ROOT}/dev/14c-provider-update-probe.sh"
}

run_stage_3_5d() {
  echo
  echo "════════════════════════════════════════════════════"
  echo "==> [RUN ] Stage 3-5d – gateway Vault credential-driver probe (always runs)"
  echo "════════════════════════════════════════════════════"
  bash "${REPO_ROOT}/dev/14d-gateway-vault-driver-probe.sh"
}

run_stage_3_5g() {
  : "${VAULT_ADDR:?VAULT_ADDR must be set for Stage 3-5g}"
  : "${VAULT_CACERT:?VAULT_CACERT must be set for Stage 3-5g}"
  run_stage "13_trusted_edge" "13-install-trusted-edge.sh"
}

run_stage_3_5h() {
  : "${VAULT_ADDR:?VAULT_ADDR must be set for Stage 3-5h}"
  : "${VAULT_CACERT:?VAULT_CACERT must be set for Stage 3-5h}"
  run_stage "13a_gateway_vault_driver" "15-install-gateway-vault-driver.sh"
}

run_stage_3_5i() {
  run_stage "13b_agent_sandbox" "16-install-agent-sandbox.sh"
}

run_stage_3_5j() {
  : "${VAULT_ADDR:?VAULT_ADDR must be set for Stage 3-5j}"
  : "${VAULT_CACERT:?VAULT_CACERT must be set for Stage 3-5j}"
  run_stage "14_camera_credential" "17-camera-credential.sh"
}

run_stage_3_5j2a() {
  echo
  echo "════════════════════════════════════════════════════"
  echo "==> [RUN ] Stage 3-5j2a – vlm-server memory/swap probe, read-only (always runs)"
  echo "════════════════════════════════════════════════════"
  bash "${REPO_ROOT}/dev/18-vlm-memory-probe.sh"
}

run_stage_3_5j2b() {
  echo
  echo "════════════════════════════════════════════════════"
  echo "==> [RUN ] Stage 3-5j2b – disable Wi-Fi, verify (always runs, no marker)"
  echo "════════════════════════════════════════════════════"
  bash "${REPO_ROOT}/scripts/19-disable-wifi.sh"
}

run_stage_3_5j2c() {
  echo
  echo "════════════════════════════════════════════════════"
  echo "==> [RUN ] Stage 3-5j2c – resync provider edge-ingest with the accepted ingest key (no marker)"
  echo "════════════════════════════════════════════════════"
  bash "${REPO_ROOT}/dev/20-resync-ingest-key.sh"
}

# Phase 5
run_stage_5_1() {
  # Only VAULT_ADDR is needed. vault tpm attest is unauthenticated —
  # the gentpmcert endpoints are protected by TPM hardware challenge, not a token.
  : "${VAULT_ADDR:?VAULT_ADDR must be set for Stage 5-1}"
  run_stage "11_tpm_agent" "11-tpm-enroll-and-agent.sh" --instance edge
}

run_stage_5_1b() {
  : "${VAULT_ADDR:?VAULT_ADDR must be set for Stage 5-1b}"
  run_stage "11b_tpm_gateway_agent" "11-tpm-enroll-and-agent.sh" --instance gateway
}

run_stage_5_2() {
  : "${VAULT_ADDR:?VAULT_ADDR must be set for Stage 5-2}"
  run_stage "12_agent_pipeline" "12-install-agent-pipeline.sh"
}

run_stage_5_3b() {
  # Marker check first: in the default order this stage is reached on every run, and the launcher only
  # stages the credential files when the marker is absent. Remove any staged files if we skip.
  if [[ -f "${STATE_DIR}/15_vault_widgets" ]]; then
    echo "==> [SKIP] Stage 15_vault_widgets already complete (marker present)."
    record_stage "15_vault_widgets" "SKIP"
    [[ -n "${CONTROL_READER_FILE:-}" ]] && rm -f "${CONTROL_READER_FILE}"
    [[ -n "${MAC_KEY_FILE:-}" ]] && rm -f "${MAC_KEY_FILE}"
    return 0
  fi
  : "${VAULT_ADDR:?VAULT_ADDR must be set for Stage 5-3b}"
  : "${VAULT_CACERT:?VAULT_CACERT must be set for Stage 5-3b}"
  : "${CONTROL_READER_FILE:?CONTROL_READER_FILE must be set - run via bootstrap-jetson.sh --only-stage 5-3b}"
  : "${MAC_KEY_FILE:?MAC_KEY_FILE must be set - run via bootstrap-jetson.sh --only-stage 5-3b}"
  run_stage "15_vault_widgets" "21-vault-widgets.sh"
}

run_stage_fix_token() {
  echo
  echo "════════════════════════════════════════════════════"
  echo "==> [RUN ] fix-vault-token-perms (no marker — always runs)"
  echo "════════════════════════════════════════════════════"
  bash "${REPO_ROOT}/dev/fix-vault-token-perms.sh"
}

# Phase pipelines
run_phase_1() {
  echo ">>> Running Phase 1 (Native VLM Server)..."
  run_stage_1_1
  run_stage_1_2
  run_stage_1_3
  run_stage_1_4
}

run_phase_2() {
  echo ">>> Running Phase 2 (Live VLM WebUI)..."
  run_stage_2_1
  run_stage_2_2
}

run_phase_3() {
  echo ">>> Running Phase 3 (NVIDIA OpenShell Edge Agent & Policy Sandbox)..."
  run_stage_3_1
  run_stage_3_5i
  run_stage_3_2   # tests the sandbox that 3-5i created
}

run_phase_5() {
  echo ">>> Running Phase 5 (End-to-End Integration — TPM + Dual Vault Agent)..."
  run_stage_5_1
  run_stage_5_1b
  run_stage_5_2
}

# Default order (Session 7-2d, F-08): every stage runs after the stages its entry checks need.
# Prerequisites read from the stage scripts on 2026-11-03 (entry checks, not run):
#   3-1  (06)  vlm-server AND live-vlm-webui active (hard exit)  -> after 1-3 and 2-1
#   3-5g (13)  markers 11_tpm_agent, 12_agent_pipeline            -> after 5-1, 5-2
#   3-5h (15)  markers 11b_tpm_gateway_agent, 13_trusted_edge; needs the OpenShell gateway -> after 5-1b, 3-5g, 3-1
#   3-5i (16)  markers 13_trusted_edge, 13a_gateway_vault_driver, 11_tpm_agent
#   3-2  (07)  sandbox camera-agent Ready                         -> after 3-5i
#   3-5j (17)  markers 11_tpm_agent, 13_trusted_edge; live-vlm-webui active (hard exit) -> after 2-1
#   5-3b (21)  markers 11, 11b, 13, 14_camera_credential, 09_webui; live-vlm-webui active -> after 3-5j and 2-1
#   2-2  (10)  WebUI smoke test                                   -> last, after the camera credential (3-5j)
# 2-1 therefore sits right after Phase 1, not at the end (3-1, 3-5j and 5-3b exit if live-vlm-webui is not active).
# 3-5g runs before 3-1 as specified; its step 8 (source-address probe sandbox) only warns when `openshell`
# is not installed yet, so on a device without OpenShell that one measurement is skipped.
run_default_order() {
  echo ">>> Default order: Phase 1 -> WebUI -> Phase 5 setup -> Phase 3 backend -> Phase 3 agent -> credential/widgets/smoke"
  # labels the end-of-run summary expects; one never reached is printed as "not run"
  DEFAULT_ORDER_LABELS=(01_prep "1-2 (no marker)" 08_services "1-4 (no marker)" 09_webui 11_tpm_agent
    11b_tpm_gateway_agent 12_agent_pipeline 13_trusted_edge 10_openshell 13a_gateway_vault_driver
    13b_agent_sandbox "3-2 (no marker)" 14_camera_credential 15_vault_widgets "2-2 (no marker)")
  # Phase 1
  run_stage_1_1
  run_stage_1_2
  run_stage_1_3
  run_stage_1_4
  # WebUI (needed active by 3-1, 3-5j, 5-3b)
  run_stage_2_1
  # Phase 5 setup
  run_stage_5_1
  run_stage_5_1b
  run_stage_5_2
  # Phase 3 backend
  run_stage_3_5g
  run_stage_3_1
  run_stage_3_5h
  # Phase 3 agent
  run_stage_3_5i
  run_stage_3_2   # tests the sandbox that 3-5i created
  # Camera credential, widgets, WebUI smoke
  run_stage_3_5j
  run_stage_5_3b
  run_stage_2_2
}

# ── dispatch ──────────────────────────────────────────────────────────────────
if [[ -n "${ONLY_STAGE}" ]]; then
  case "${ONLY_STAGE}" in
    1|1-1|01_prep|prep)                        run_stage_1_1 ;;
    3|1-2|03_download_model|model)             run_stage_1_2 ;;
    4|1-3|08_services|vlm|vlm-server)          run_stage_1_3 ;;
    5|1-4|vlm-smoke|smoke)                     run_stage_1_4 ;;
    2|2-1|09_webui|webui|webui-server)         run_stage_2_1 ;;
    2-2|webui-smoke)                           run_stage_2_2 ;;
    3|3-1|10_openshell|openshell)              run_stage_3_1 ;;
    3-2|openshell-test|openshell-policy|openshell-smoke) run_stage_3_2 ;;
    3-4a|sandbox-smoke)                        run_stage_3_4a ;;
    3-4b|agent-sandbox-test)                   run_stage_3_4b ;;
    3-5a|provider-probe)                       run_stage_3_5a ;;
    3-5c|provider-update-probe)                run_stage_3_5c ;;
    3-5d|gateway-vault-driver-probe)           run_stage_3_5d ;;
    3-5g|13_trusted_edge|trusted-edge)         run_stage_3_5g ;;
    3-5h|13a_gateway_vault_driver|gateway-vault-driver) run_stage_3_5h ;;
    3-5i|13b_agent_sandbox|agent-sandbox)               run_stage_3_5i ;;
    3-5j|14_camera_credential|camera-credential)        run_stage_3_5j ;;
    3-5j2a|vlm-memory-probe)                            run_stage_3_5j2a ;;
    3-5j2b|wifi-off)                                    run_stage_3_5j2b ;;
    3-5j2c|ingest-key-resync)                           run_stage_3_5j2c ;;
    5-1|11_tpm_agent|tpm-agent|tpm|tpm-enroll) run_stage_5_1 ;;
    5-1b|11b_tpm_gateway_agent|tpm-gateway-agent|gateway-agent|gateway-tpm) run_stage_5_1b ;;
    5-2|12_agent_pipeline|agent-pipeline|data-pipeline) run_stage_5_2 ;;
    5-3b|15_vault_widgets|vault-widgets) run_stage_5_3b ;;
    fix-token|fix-token-perms|token-perms) run_stage_fix_token ;;
    *)
      echo "ERROR: Unknown stage '${ONLY_STAGE}'."
      echo "Valid values:"
      echo "  Phase 1: 1-1 (prep), 1-2 (model), 1-3 (vlm), 1-4 (vlm-smoke)"
      echo "  Phase 2: 2-1 (webui), 2-2 (webui-smoke)"
      echo "  Phase 3: 3-1 (openshell), 3-2 (openshell-test), 3-4a (sandbox-smoke), 3-4b (agent-sandbox-test), 3-5a (provider-probe), 3-5c (provider-update-probe), 3-5d (gateway-vault-driver-probe), 3-5g (trusted-edge), 3-5h (gateway-vault-driver), 3-5i (agent-sandbox), 3-5j (camera-credential), 3-5j2a (vlm-memory-probe), 3-5j2b (wifi-off), 3-5j2c (ingest-key-resync)"
      echo "  Phase 5: 5-1 (tpm-agent), 5-1b (tpm-gateway-agent), 5-2 (agent-pipeline), 5-3b (vault-widgets)"
      exit 1
      ;;
  esac
elif [[ -n "${PHASE}" ]]; then
  case "${PHASE}" in
    1) run_phase_1 ;;
    2) run_phase_2 ;;
    3) run_phase_3 ;;
    5) run_phase_5 ;;
    *)
      echo "ERROR: Unknown phase '${PHASE}'. Valid values: 1, 2, 3, 5"
      exit 1
      ;;
  esac
else
  # Default: run all stages in dependency order (see run_default_order)
  run_default_order
  echo
  echo "╔════════════════════════════════════════════════════╗"
  echo "║  All setup stages complete.                       ║"
  echo "╚════════════════════════════════════════════════════╝"
fi

echo
echo "Active state markers:"
ls -1 "${STATE_DIR}/"
