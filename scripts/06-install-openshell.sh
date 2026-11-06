#!/usr/bin/env bash
# scripts/06-install-openshell.sh
# Phase 3 Stage 1 (3-1) – Install NVIDIA OpenShell on the Jetson (gateway + docker compute driver).
# Trimmed in Session 3-5j: the former "render policy with a python3 sha256 pin into
# /etc/openshell/agent-policy.yaml" step was invalid for OpenShell v0.1.4 (the policy is passed to
# `openshell sandbox create --policy agent/policy.yaml`; there is no digest pin or rendered copy) and is gone.
#
# Actions:
#   1. Entry checks: uname -r >= 6.2 (Landlock ABI 3); vlm-server and
#      live-vlm-webui both active (Phase 1 & 2 must be healthy).
#   2. Install OpenShell via the official installer (idempotent).
#   2b. Docker compute driver: `jetson` must be in the docker group (it is root-equivalent, THREAT_MODEL T-04);
#       write ~jetson/.config/openshell/gateway.toml with compute_driver = "docker", chown it to jetson,
#       restart the user unit `openshell-gateway`.
#   3. Verify the CLI reaches the gateway (`openshell sandbox list`).
#   4. Enable user-session linger so the gateway user unit survives SSH disconnects.
#   5. Remove two stale artefacts of the retracted Session 3-1/3-2 design if present:
#      /etc/openshell/agent-policy.yaml (rendered copy) and /var/log/openshell/audit.log
#      (written by the old simulated test, not by OpenShell).
#
# The sandbox policy lives in agent/policy.yaml and is applied by stage 3-5i (`sandbox create --policy`).
# Real enforcement evidence: stage 3-2 (07-test-openshell-policy.sh) and `openshell logs <sandbox> --source sandbox`.
#
# Expects SUDO_PASS env var (set by setup-jetson.sh).
# State marker written by setup-jetson.sh: .setup-state/10_openshell

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

POLICY_SRC="${REPO_ROOT}/agent/policy.yaml"
# T-38: pin the release. Doc: https://docs.nvidia.com/openshell/latest/about/installation.md
# ("To install a specific release, set OPENSHELL_VERSION to a release tag"). Both the installer script
# (taken from the v0.1.4 tag, not main) and the artifact it installs (OPENSHELL_VERSION) are pinned.
# Measured 2026-11-02: the v0.1.4 install.sh returns HTTP 200 and reads ${OPENSHELL_VERSION}.
# No checksum/signature of the installer is verified here (remaining part of T-38).
OPENSHELL_VERSION="v0.1.4"
OPENSHELL_INSTALLER="https://raw.githubusercontent.com/NVIDIA/OpenShell/${OPENSHELL_VERSION}/install.sh"

# Minimum kernel for full Landlock ABI 3 (JetPack 7.2.1 = 6.8.12-tegra).
KERNEL_MIN_MAJOR=6
KERNEL_MIN_MINOR=2

sudocmd() { echo "${SUDO_PASS}" | sudo -S "$@"; }

echo "── Phase 3 Stage 1 (3-1): Install OpenShell Edge Supervisor ───────────"

# ── 1. Entry checks ─────────────────────────────────────────────────────
KERNEL="$(uname -r | sed 's/^v//; s/-.*//')"   # e.g. 6.8.12
KERNEL_MAJOR="${KERNEL%%.*}"
KERNEL_REST="${KERNEL#*.}"
KERNEL_MINOR="${KERNEL_REST%%.*}"

if [[ "${KERNEL_MAJOR}" -gt "${KERNEL_MIN_MAJOR}" ]] || \
   { [[ "${KERNEL_MAJOR}" -eq "${KERNEL_MIN_MAJOR}" ]] && [[ "${KERNEL_MINOR}" -ge "${KERNEL_MIN_MINOR}" ]]; }; then
  echo "    Kernel ${KERNEL} >= ${KERNEL_MIN_MAJOR}.${KERNEL_MIN_MINOR} (Landlock ABI 3 available)."
else
  echo "ERROR: kernel ${KERNEL} is below ${KERNEL_MIN_MAJOR}.${KERNEL_MIN_MINOR}."
  echo "       OpenShell needs Landlock ABI 3 (uname -r >= 6.2). Aborting."
  exit 1
fi

# Phase 1 + Phase 2 services must be up before we sandbox the camera agent.
echo "--> Checking Phase 1 & 2 services are active (vlm-server, live-vlm-webui)..."
if ! systemctl is-active --quiet vlm-server live-vlm-webui 2>/dev/null; then
  echo "ERROR: vlm-server and/or live-vlm-webui is not active."
  echo "       Run Phase 1 (vlm-server) and Phase 2 (live-vlm-webui) first."
  echo "       Status: $(systemctl is-active vlm-server 2>/dev/null || echo unknown) / $(systemctl is-active live-vlm-webui 2>/dev/null || echo unknown)"
  exit 1
fi
echo "    vlm-server and live-vlm-webui: active."

if [[ ! -f "${POLICY_SRC}" ]]; then
  echo "ERROR: ${POLICY_SRC} missing — create agent/policy.yaml first."
  exit 1
fi

# ── 2. Install OpenShell (official installer, idempotent) ──────────────
if command -v openshell >/dev/null 2>&1; then
  echo "--> OpenShell already installed: $(command -v openshell)"
else
  echo "--> Installing OpenShell ${OPENSHELL_VERSION} via official installer..."
  curl -LsSf "${OPENSHELL_INSTALLER}" | OPENSHELL_VERSION="${OPENSHELL_VERSION}" sh
  echo "    OpenShell installed: $(command -v openshell)"
fi
# ── 2b. Configure the OpenShell compute driver (docker) ───────────────────
# The gateway auto-detects Kubernetes -> Podman -> Docker. It runs as user `jetson`, which needs
# access to the Docker socket (docker group). Pin compute_driver = "docker" explicitly.
echo "--> Configuring OpenShell compute driver (docker)..."

# Make the jetson user able to reach the Docker daemon socket.
if ! groups jetson | grep -q '\bdocker\b'; then
  sudocmd usermod -aG docker jetson
  echo "    Added jetson to the docker group (takes effect on next login)."
else
  echo "    jetson is already in the docker group."
fi

# Locate (or create) the gateway TOML and pin the docker compute driver.
# Config preflight requires [openshell] version = 2 plus a compute driver.
GATEWAY_CONFIG_CANDIDATES=(
  "/home/jetson/.config/openshell/gateway.toml"
  "/etc/openshell/gateway.toml"
  "${HOME}/.config/openshell/gateway.toml"
)
GATEWAY_CONFIG=""
for c in "${GATEWAY_CONFIG_CANDIDATES[@]}"; do
  if [[ -f "${c}" ]]; then
    GATEWAY_CONFIG="${c}"
    break
  fi
done
if [[ -z "${GATEWAY_CONFIG}" ]]; then
  GATEWAY_CONFIG="/home/jetson/.config/openshell/gateway.toml"
  sudocmd mkdir -p "$(dirname "${GATEWAY_CONFIG}")"
  echo "    No existing gateway TOML found; creating ${GATEWAY_CONFIG}."
fi

# Write the minimal gateway config with the docker compute driver pinned - but NEVER overwrite a
# config that already pins docker: stage 3-5h adds credential_drivers = ["vault"] to this file and a
# --reset-stage 3-1 re-run must not silently remove it.
if [[ -f "${GATEWAY_CONFIG}" ]] && sudocmd grep -qE '^\s*compute_driver\s*=\s*"docker"' "${GATEWAY_CONFIG}"; then
  echo "    ${GATEWAY_CONFIG} already pins compute_driver = \"docker\"; left unchanged."
else
  GATEWAY_TMP="$(mktemp /tmp/openshell-gateway.XXXXXX.toml)"
  cat > "${GATEWAY_TMP}" <<'TOML'
[openshell]
version = 2

[openshell.gateway]
compute_driver = "docker"

[openshell.drivers.docker]
socket_path = "/var/run/docker.sock"
TOML
  sudocmd cp "${GATEWAY_TMP}" "${GATEWAY_CONFIG}"
  sudocmd chmod 644 "${GATEWAY_CONFIG}"
  rm -f "${GATEWAY_TMP}"
  echo "    Gateway compute driver configured: docker (${GATEWAY_CONFIG})."
fi
# The file lives in the jetson user's home and is edited by user-level stages (3-5d/3-5h): keep it jetson-owned.
case "${GATEWAY_CONFIG}" in /home/jetson/*) sudocmd chown jetson:jetson "${GATEWAY_CONFIG}" ;; esac

# Restart the gateway user service so it picks up the compute driver.
# The script runs as the jetson user over SSH, so use systemctl --user directly
# (no sudo) against jetson's own systemd user instance.
echo "--> Restarting openshell-gateway user service..."
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
if systemctl --user restart openshell-gateway; then
  echo "    Gateway restarted as user jetson."
else
  echo "    WARNING: gateway restart failed; check: journalctl --user -u openshell-gateway"
fi

# Give the gateway a moment to come up.
sleep 3

# Verify the gateway actually came up with the docker compute driver.
# OpenShell v0.1.4 exposes no "sandbox status" subcommand; use `sandbox list`
# which proves the CLI can reach the healthy gateway.
GATEWAY_OK=false
for i in $(seq 1 6); do
  sleep 2
  if openshell sandbox list >/dev/null 2>&1; then
    GATEWAY_OK=true
    break
  fi
  echo "    ... waiting for gateway (${i}/6)"
done

if [[ "${GATEWAY_OK}" != "true" ]]; then
  echo
  echo "ERROR: the OpenShell gateway did not come up with the docker compute driver."
  echo "       Most likely cause: a docker-group change only takes effect in a NEW login"
  echo "       session. Start a fresh SSH session and re-run:"
  echo "           ./scripts/bootstrap-jetson.sh <jetson-ip> --only-stage 3-1"
  echo "       Journal: journalctl --user -u openshell-gateway -n 40 --no-pager"
  exit 1
fi

# ── 3. Verify the CLI reaches the gateway ───────────────────────────────────
# OpenShell v0.1.4 has no "sandbox status" subcommand; `openshell sandbox list` proves the CLI
# reaches the gateway.
echo "--> Verifying OpenShell gateway is reachable via the CLI..."
if ! openshell sandbox list >/dev/null 2>&1; then
  echo "ERROR: openshell CLI cannot reach the gateway at 127.0.0.1:17670."
  echo "       Check: journalctl --user -u openshell-gateway -n 40 --no-pager"
  exit 1
fi
echo "    OpenShell gateway reachable (configured compute driver: docker)."

# ── 4. Enable user session linger so openshell-gateway survives SSH disconnects ──
# Without this, Linger=no means the jetson user's systemd session (and all its
# user services, including openshell-gateway) is torn down whenever the last
# SSH session closes. loginctl enable-linger makes the session persistent.
if loginctl show-user jetson --property=Linger 2>/dev/null | grep -q "Linger=yes"; then
  echo "    User session linger already enabled for jetson."
else
  sudocmd loginctl enable-linger jetson
  echo "    Enabled user session linger for jetson (gateway survives SSH disconnect)."
fi

# ── 5. Remove stale artefacts of the retracted design ─────────────────────────
# /etc/openshell/agent-policy.yaml: rendered copy with a digest pin that v0.1.4 never reads.
# /var/log/openshell/audit.log: contents were written by the old simulated test, not by OpenShell.
for stale in /etc/openshell/agent-policy.yaml /var/log/openshell/audit.log; do
  if sudocmd test -e "${stale}"; then
    sudocmd rm -f "${stale}"
    echo "    Removed stale artefact: ${stale}"
  fi
done

echo
echo "── Phase 3 Stage 1 (3-1) complete ────────────────────────────────────"
echo "    OpenShell binary      : $(command -v openshell)"
echo "    Gateway compute driver: docker (${GATEWAY_CONFIG})"
echo "    Next                  : stage 3-5i creates the sandbox with --policy agent/policy.yaml"
