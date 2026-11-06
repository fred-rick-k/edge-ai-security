#!/usr/bin/env bash
# scripts/reset-all.sh
# Jetson-side helper for `bootstrap-jetson.sh --reset-all` (Session 7-2d, user decision 2026-11-03).
# Never run by hand; the launcher calls it (AGENTS.md section 1) with one mode:
#
#   list     print what reset-all will remove / keep. Changes nothing.
#   chain    delete the ingest-key chain on the Jetson: sandbox camera-agent (and the 3-5g probe sandbox),
#            providers edge-ingest + cosmos-vlm, profiles edge-ingest + cosmos-vlm.
#            Deleting a provider makes the gateway Vault driver remove its KV entry
#            (edge-ai-demo-gateway/openshell/provider-credentials/...; same mechanism cleanup-jetson.sh uses).
#   markers  remove every file in .setup-state/.
#
# Why the chain must go with the markers (read from scripts 13/15/16 on 2026-11-03, not run):
#   3-5h deletes /etc/trusted-edge/ingest-key.handoff; a re-run of 3-5g then generates a NEW key and aborts with
#   EXISTS_DIFFERENT against the create-only SHA-256 in Vault KV edge-device/ingest-key (that delete is done by the
#   launcher on the Mac, not here); provider edge-ingest and the camera-agent sandbox would still hold the old key.
#
# Kept on purpose: /etc/webui-vault/admin-key (5-3b reuses it; its KV hash is left alone), models/, venvs,
# systemd units, gateway.toml, TPM state, Docker images.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${REPO_ROOT}/.setup-state"
HANDOFF_KEY="/etc/trusted-edge/ingest-key.handoff"
ADMIN_KEY="/etc/webui-vault/admin-key"
SANDBOXES=(camera-agent te-src-probe)
PROVIDERS=(edge-ingest cosmos-vlm)
PROFILES=(edge-ingest cosmos-vlm)

MODE="${1:-}"
[[ "${MODE}" == "list" || "${MODE}" == "chain" || "${MODE}" == "markers" ]] \
  || { echo "usage: reset-all.sh list|chain|markers (called by bootstrap-jetson.sh --reset-all)" >&2; exit 2; }

export XDG_RUNTIME_DIR="/run/user/$(id -u)"
sudocmd() { echo "${SUDO_PASS}" | sudo -S "$@" 2>/dev/null; }

has_sandbox()  { openshell sandbox list 2>/dev/null | awk -v n="$1" '$1==n {f=1} END{exit !f}'; }
has_provider() { openshell provider list 2>/dev/null | grep -q "^$1 "; }
has_profile()  { openshell profile list 2>/dev/null | grep -q "^$1 "; }

case "${MODE}" in
  list)
    echo "Stage markers in ${STATE_DIR} (ALL will be removed):"
    if compgen -G "${STATE_DIR}/*" >/dev/null; then ls -1 "${STATE_DIR}" | sed 's/^/    /'; else echo "    (none)"; fi
    echo "OpenShell objects that will be deleted if present (ingest-key chain):"
    for s in "${SANDBOXES[@]}"; do has_sandbox  "$s" && echo "    sandbox  $s : PRESENT" || echo "    sandbox  $s : absent"; done
    for p in "${PROVIDERS[@]}"; do has_provider "$p" && echo "    provider $p : PRESENT (its Vault KV entry goes with it)" || echo "    provider $p : absent"; done
    for p in "${PROFILES[@]}";  do has_profile  "$p" && echo "    profile  $p : PRESENT" || echo "    profile  $p : absent"; done
    echo "Ingest key handoff file ${HANDOFF_KEY}: $(sudocmd test -e "${HANDOFF_KEY}" && echo 'present (left alone; 3-5g reuses it)' || echo 'absent (3-5g will generate a new key)')"
    echo "Kept: $(sudocmd test -e "${ADMIN_KEY}" && echo "${ADMIN_KEY} (present)" || echo "${ADMIN_KEY} (absent)"), models, venvs, systemd units, gateway.toml, TPM state, Docker images"
    ;;
  chain)
    command -v openshell >/dev/null 2>&1 || { echo "openshell not installed: nothing to delete in the chain"; exit 0; }
    for s in "${SANDBOXES[@]}"; do
      if has_sandbox "$s"; then echo "--> deleting sandbox $s"; openshell sandbox delete "$s" || true; fi
    done
    sleep 2
    for p in "${PROVIDERS[@]}"; do
      if has_provider "$p"; then echo "--> deleting provider $p"; openshell provider delete "$p" || true; fi
    done
    for p in "${PROFILES[@]}"; do
      if has_profile "$p"; then echo "--> deleting profile $p"; openshell profile delete "$p" || true; fi
    done
    # Verify what the CLI reports now; fail so the launcher stops before it touches Vault on the Mac.
    left=0
    for s in "${SANDBOXES[@]}"; do has_sandbox  "$s" && { echo "ERROR: sandbox $s still exists" >&2; left=1; }; done
    for p in "${PROVIDERS[@]}"; do has_provider "$p" && { echo "ERROR: provider $p still exists" >&2; left=1; }; done
    for p in "${PROFILES[@]}";  do has_profile  "$p" && { echo "ERROR: profile $p still exists" >&2; left=1; }; done
    [[ ${left} -eq 0 ]] || exit 1
    echo "chain deleted (openshell CLI lists none of: ${SANDBOXES[*]} ${PROVIDERS[*]}). Vault KV entries not read back here."
    ;;
  markers)
    if compgen -G "${STATE_DIR}/*" >/dev/null; then
      for m in "${STATE_DIR}"/*; do echo "--> removing marker $(basename "${m}")"; rm -f "${m}"; done
    else
      echo "no markers present"
    fi
    ;;
esac
