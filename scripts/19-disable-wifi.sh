#!/usr/bin/env bash
# scripts/19-disable-wifi.sh
# Phase 3 Stage 3-5j2b (wifi-off) – turn the Jetson's Wi-Fi off, persistently, and verify it.
# Idempotent, no stage marker (it is cheap and re-checks the live state every run).
#
# Why (2026-10-18, measured on the device, see CHANGELOG Session 3-5j2):
#   - wlP1p1s0 (<wifi-ip>) and enP8p1s0 (<jetson-ip>) were both up on the same /24.
#   - `jetson.localdomain` resolved to <wifi-ip> first; the OpenShell supervisor logged
#     "Policy DNS mapped jetson.localdomain resolved=<wifi-ip>" and then NET:FAIL on :8095,
#     because trusted-edge binds only <jetson-ip> (TE_BIND). The camera-agent lost its frames.
#   - The camera, Vault and the VLM are all reached over Ethernet; nothing needs Wi-Fi.
#   - Turning the radio off does NOT fix the name: the router DNS keeps answering <wifi-ip> (see the
#     /etc/hosts pin below), so the stage also pins jetson.localdomain to the Ethernet address.
#
# Mechanism (documented, nmcli(1) on the device, NetworkManager 1.46):
#   `nmcli radio wifi off`                          – NetworkManager's software Wi-Fi switch; NM
#                                                     stores its state persistently (NetworkManager(8)
#                                                     --state-file, default
#                                                     /var/lib/NetworkManager/NetworkManager.state)
#   `nmcli connection modify <c> connection.autoconnect no` – so the saved profile (macnet) does not
#                                                     bring the radio's link up if it is switched on again.
# Whether the radio stays off across a REBOOT is checked here only through the state file
# (WirelessEnabled=false); a real reboot test has not been done: unverified until it is.
#
# Safety (the stage aborts instead of continuing):
#   - refuses to run if the SSH session comes in through the Wi-Fi address,
#   - refuses to run if there is no connected Ethernet device with a default route.
#
# Expects SUDO_PASS env var (set by setup-jetson.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1090,SC1091
  source "${REPO_ROOT}/.env"
  set +a
fi

sudocmd() { echo "${SUDO_PASS}" | sudo -S -p '' "$@"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

echo "── Stage 3-5j2b: disable Wi-Fi (persistent) ──────────────────────────"

DISABLE_WIFI="${DISABLE_WIFI:-true}"
case "${DISABLE_WIFI,,}" in
  false|0|no|n|off|disabled)
    echo "    DISABLE_WIFI is set to '${DISABLE_WIFI}'. Skipping Wi-Fi disable."
    exit 0
    ;;
esac

JETSON_HOSTNAME="${JETSON_HOSTNAME:-jetson.localdomain}"

command -v nmcli >/dev/null || fail "nmcli not found"

mapfile -t WIFI_DEVS < <(nmcli -t -f DEVICE,TYPE dev | awk -F: '$2=="wifi" {print $1}')
if [[ "${#WIFI_DEVS[@]}" -eq 0 ]]; then
  echo "    No Wi-Fi device present. Nothing to do."
  exit 0
fi
echo "    Wi-Fi device(s): ${WIFI_DEVS[*]}"

# ── safety ────────────────────────────────────────────────────────────────────
ETH_DEV="$(nmcli -t -f DEVICE,TYPE,STATE dev | awk -F: '$2=="ethernet" && $3=="connected" {print $1; exit}')"
[[ -n "${ETH_DEV}" ]] || fail "no connected Ethernet device; refusing to cut the only link"
ip route show default | grep -q " dev ${ETH_DEV} " || fail "no default route via ${ETH_DEV}; refusing"
echo "    Ethernet device ${ETH_DEV} is connected and has a default route."

SSH_SERVER_IP="$(awk '{print $3}' <<<"${SSH_CONNECTION:-}")"
for d in "${WIFI_DEVS[@]}"; do
  WIP="$(ip -4 -o addr show dev "${d}" 2>/dev/null | awk '{sub(/\/.*/,"",$4); print $4}')"
  if [[ -n "${WIP}" && -n "${SSH_SERVER_IP}" && "${WIP}" == "${SSH_SERVER_IP}" ]]; then
    fail "this SSH session is on the Wi-Fi address ${WIP}; reconnect over Ethernet first"
  fi
done

# ── apply ─────────────────────────────────────────────────────────────────────
echo "--> Setting connection.autoconnect=no on saved Wi-Fi profiles..."
while IFS=: read -r name type; do
  [[ "${type}" == "802-11-wireless" ]] || continue
  sudocmd nmcli connection modify "${name}" connection.autoconnect no
  echo "    profile '${name}': autoconnect -> no"
done < <(nmcli -t -f NAME,TYPE connection show)

echo "--> nmcli radio wifi off ..."
sudocmd nmcli radio wifi off
sleep 3

# ── verify (kernel/NM state, not the command's exit code) ─────────────────────
echo "--> Verifying..."
VFAIL=0
vfail() { echo "    FAIL: $*"; VFAIL=1; }
ok()    { echo "    ok:   $*"; }

RADIO="$(nmcli radio wifi)"
[[ "${RADIO}" == "disabled" ]] && ok "nmcli radio wifi = disabled" || vfail "nmcli radio wifi = '${RADIO}'"

for d in "${WIFI_DEVS[@]}"; do
  ST="$(nmcli -t -f DEVICE,STATE dev | awk -F: -v d="${d}" '$1==d {print $2}')"
  [[ "${ST}" != "connected" && "${ST}" != connecting* ]] && ok "${d} state = ${ST}" || vfail "${d} state = ${ST}"
  A="$(ip -4 -o addr show dev "${d}" 2>/dev/null | awk '{print $4}')"
  [[ -z "${A}" ]] && ok "${d} has no IPv4 address" || vfail "${d} still has IPv4 ${A}"
  ip route show | grep -q " dev ${d} " && vfail "routes via ${d} remain" || ok "no route via ${d}"
done

while IFS=: read -r name type; do
  [[ "${type}" == "802-11-wireless" ]] || continue
  AC="$(nmcli -g connection.autoconnect connection show "${name}")"
  [[ "${AC}" == "no" ]] && ok "profile '${name}' autoconnect = no" || vfail "profile '${name}' autoconnect = '${AC}'"
done < <(nmcli -t -f NAME,TYPE connection show)

STATE_FILE="/var/lib/NetworkManager/NetworkManager.state"
if sudocmd test -r "${STATE_FILE}"; then
  WE="$(sudocmd grep -E '^WirelessEnabled=' "${STATE_FILE}" || true)"
  echo "    state file ${STATE_FILE}: ${WE:-<no WirelessEnabled line>}"
  [[ "${WE}" == "WirelessEnabled=true" ]] && vfail "state file still says WirelessEnabled=true (would come back after reboot)"
else
  echo "    state file ${STATE_FILE} not readable: persistence NOT checked"
fi

# ── pin jetson.localdomain to the Ethernet address in /etc/hosts ──────────────
# 2026-10-18 first run (verified): with Wi-Fi off, `jetson.localdomain` still resolved to the Wi-Fi
# address <wifi-ip>, answered by the router DNS (<router-ip>; resolvectl: "Data from: network"). Both NICs
# send the hostname `jetson` by DHCP and the router seems to keep the last lease's address (INFERRED; the
# router is not visible from here). The Wi-Fi lease lasts ~24 h, so waiting is not a fix.
# /etc/nsswitch.conf on the device has `hosts: files mdns4_minimal [NOTFOUND=return] dns` (verified),
# i.e. /etc/hosts is consulted before DNS. This makes the name independent of the router. The address is
# read from the Ethernet device, not hard-coded. A managed block keeps the stage idempotent.
ETH_IP="$(ip -4 -o addr show dev "${ETH_DEV}" scope global | awk '{sub(/\/.*/,"",$4); print $4; exit}')"
[[ -n "${ETH_IP}" ]] || fail "no IPv4 address on ${ETH_DEV}"
HOSTS_BEGIN="# BEGIN edge-device-demo ${JETSON_HOSTNAME} (scripts/19-disable-wifi.sh)"
HOSTS_END="# END edge-device-demo ${JETSON_HOSTNAME}"
HOSTS_TMP="$(mktemp /tmp/hosts.XXXXXX)"
sudocmd cat /etc/hosts | awk -v b="${HOSTS_BEGIN}" -v e="${HOSTS_END}" '$0==b{skip=1} !skip{print} $0==e{skip=0}' > "${HOSTS_TMP}"
printf '%s\n%s %s\n%s\n' "${HOSTS_BEGIN}" "${ETH_IP}" "${JETSON_HOSTNAME}" "${HOSTS_END}" >> "${HOSTS_TMP}"
if sudocmd cmp -s "${HOSTS_TMP}" /etc/hosts; then
  echo "--> /etc/hosts already pins ${JETSON_HOSTNAME} -> ${ETH_IP}"
else
  sudocmd cp /etc/hosts /etc/hosts.pre-3-5j2b 2>/dev/null || true
  sudocmd cp "${HOSTS_TMP}" /etc/hosts
  sudocmd chmod 644 /etc/hosts
  echo "--> /etc/hosts: pinned ${JETSON_HOSTNAME} -> ${ETH_IP} (backup /etc/hosts.pre-3-5j2b)"
fi
rm -f "${HOSTS_TMP}"

# ── the symptom: jetson.localdomain must resolve only to an address on this host ──
echo "--> Name resolution of ${JETSON_HOSTNAME} (the symptom behind this stage):"
LOCAL_IPS="$(ip -4 -o addr show scope global | awk '{sub(/\/.*/,"",$4); print $4}')"
RES_OK=0
for i in $(seq 1 12); do
  ADDRS="$(getent ahostsv4 "${JETSON_HOSTNAME}" | awk '{print $1}' | sort -u | tr '\n' ' ')"
  BAD=""
  for a in ${ADDRS}; do grep -qx "${a}" <<<"${LOCAL_IPS}" || BAD="${BAD} ${a}"; done
  if [[ -n "${ADDRS}" && -z "${BAD}" ]]; then RES_OK=1; break; fi
  echo "    [${i}/12] ${JETSON_HOSTNAME} -> ${ADDRS:-<none>}; not on this host:${BAD:- <none>}; waiting 5 s"
  sleep 5
done
if [[ "${RES_OK}" -eq 1 ]]; then
  ok "${JETSON_HOSTNAME} -> ${ADDRS}(all local)"
else
  vfail "${JETSON_HOSTNAME} still resolves to an address that is not on this host (${ADDRS}) even with the /etc/hosts pin; check /etc/nsswitch.conf and /etc/hosts."
fi

if [[ "${VFAIL}" -ne 0 ]]; then
  echo
  echo "ERROR: Wi-Fi is not fully off / name resolution not clean (see FAIL lines)."
  exit 1
fi
echo
echo "── Stage 3-5j2b complete: Wi-Fi radio off, profile autoconnect off, no Wi-Fi address/route. ──"
echo "    Reboot persistence: state file checked only; a real reboot test is still pending (unverified)."
