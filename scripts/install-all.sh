#!/usr/bin/env bash
# scripts/install-all.sh   (runs on the WORKSTATION - the only machine that can SSH to both hosts)
#
# Session 7-2e - one parent installer: Mac control plane -> Jetson edge device -> end-to-end smoke test.
#
#   ./scripts/install-all.sh [jetson-ip|user@jetson-ip] [--force-tls] [--skip-smoke]
#
# Order (and why - read from the scripts, not yet run end to end):
#   1. bootstrap-mac.sh  --only-step sync,env,tls,cert,up,vault
#        Vault must be up, initialised and unsealed before any Jetson stage; tls/vault.crt must exist before
#        bootstrap-jetson.sh copies it to the device.
#   2. tpm2-tools gate: `make setup-tpm-auth` (Mac) calls `tpm2_createek` ON THE JETSON. Stage 1-1 installs tpm2-tools
#        (7-2e). If `tpm2_createek` is missing, this script runs `bootstrap-jetson.sh --only-stage 1-1` (one extra sudo
#        prompt) and checks again. If it is STILL missing (stage 1-1 marker present from an older run), it stops and
#        names the fix: `bootstrap-jetson.sh <ip> --reset-stage 1-1`.
#   3. bootstrap-mac.sh  --only-step tpm,roles,reader,resume
#        stage 5-1 needs the TPM enrolled on the Mac; 5-1b needs the gateway role; 5-3b needs the control-plane-reader
#        role_id/secret_id. On a fresh install `reader` reports "proofs not run" (no events yet) - that is expected.
#   4. bootstrap-jetson.sh <ip>   (default stage order; prompts for the Jetson sudo password; prints its own stage table)
#   5. bootstrap-mac.sh  --only-step reader     (now there are stored events, so the narrowness proofs can RUN)
#   6. make demo-smoke-test on the Mac over SSH (AGENTS.md section 1.1). Exit code is the gate; its output is shown.
#
# Every phase prints RUN-OK / FAIL / not run in the summary at the end. A phase that did not start is "not run".
# `--reset-all` is NOT offered here (it deletes the ingest-key chain and needs its own typed RESET): run
# `bootstrap-jetson.sh <ip> --reset-all` yourself before this script if you want a from-scratch Jetson.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

[[ -f .env ]] || { echo "ERROR: .env not found (cp .env.example .env and fill it in)" >&2; exit 1; }
set -a
# shellcheck disable=SC1091
source .env
set +a

TARGET=""
FORCE_TLS=""
SKIP_SMOKE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force-tls)  FORCE_TLS="--force-tls"; shift ;;
    --skip-smoke) SKIP_SMOKE=true; shift ;;
    --*)          echo "Unknown flag: $1" >&2; exit 1 ;;
    *)            TARGET="$1"; shift ;;
  esac
done
JETSON_HOST_ARG="${TARGET:-${JETSON_IP:?JETSON_IP missing in .env}}"
J_USER="${JETSON_USER:?JETSON_USER missing in .env}"; J_IP="${JETSON_HOST_ARG##*@}"
[[ "${JETSON_HOST_ARG}" == *"@"* ]] && J_USER="${JETSON_HOST_ARG%@*}"
J_KEY="${JETSON_SSH_KEY/#\~/$HOME}"
M_KEY="${MAC_SSH_KEY/#\~/$HOME}"

PHASES=("mac-base" "tpm2-gate" "mac-tpm-roles" "jetson" "mac-proofs" "smoke-test")
LOG=()
CURRENT=""
finish() {
  local rc=$? p e s
  [[ -n "${CURRENT}" ]] && LOG+=("${CURRENT}|FAIL")
  echo
  echo "════════════ install-all summary (exit ${rc}) ════════════"
  for p in "${PHASES[@]}"; do
    s="not run"; for e in "${LOG[@]:-}"; do [[ "${e%%|*}" == "${p}" ]] && s="${e#*|}"; done
    printf '  %-14s %s\n' "${p}" "${s}"
  done
  echo "══════════════════════════════════════════════════════════"
  exit "${rc}"
}
trap finish EXIT
phase() { CURRENT="$1"; echo; echo "################ phase: $1 ################"; }
ok_phase() { LOG+=("$1|$2"); CURRENT=""; }

tpm2_present() {
  ssh -i "${J_KEY}" -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new "${J_USER}@${J_IP}" \
    'command -v tpm2_createek >/dev/null 2>&1' 2>/dev/null
}

# 1
phase mac-base
./scripts/bootstrap-mac.sh --only-step sync,env,tls,cert,up,vault ${FORCE_TLS}
ok_phase mac-base RUN-OK

# 2
phase tpm2-gate
if tpm2_present; then
  echo "  ✓ tpm2_createek found on ${J_USER}@${J_IP}"
  ok_phase tpm2-gate "RUN-OK (already present)"
else
  echo "  ▷ tpm2_createek not found (or the Jetson is not reachable by key yet): running stage 1-1 first"
  ./scripts/bootstrap-jetson.sh "${J_USER}@${J_IP}" --only-stage 1-1
  if tpm2_present; then
    echo "  ✓ tpm2_createek found after stage 1-1"
    ok_phase tpm2-gate "RUN-OK (stage 1-1 ran)"
  else
    echo "  ✗ tpm2_createek still missing on ${J_USER}@${J_IP}. If stage 1-1 printed [SKIP] its marker predates the tpm2-tools change:" >&2
    echo "    ./scripts/bootstrap-jetson.sh ${J_USER}@${J_IP} --reset-stage 1-1" >&2
    exit 1
  fi
fi

# 3
phase mac-tpm-roles
./scripts/bootstrap-mac.sh --only-step tpm,roles,reader,resume
ok_phase mac-tpm-roles RUN-OK

# 4
phase jetson
./scripts/bootstrap-jetson.sh "${J_USER}@${J_IP}"
ok_phase jetson RUN-OK

# 5
phase mac-proofs
./scripts/bootstrap-mac.sh --only-step reader
ok_phase mac-proofs RUN-OK

# 6
if ${SKIP_SMOKE}; then
  echo; echo "smoke-test skipped by --skip-smoke (shown as 'not run')"
else
  phase smoke-test
  ssh -i "${M_KEY}" -o BatchMode=yes -o ConnectTimeout=15 "${MAC_USER}@${MAC_IP}" \
    'export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; cd ~/edge-device-demo && make demo-smoke-test'
  ok_phase smoke-test RUN-OK
fi

echo
echo "==> install-all finished. The summary lists each phase; read each script's own PASS lines above for what was actually checked."
