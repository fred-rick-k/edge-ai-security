#!/usr/bin/env bash
# scripts/09-install-webui.sh
# Phase 2 Stage 1 (2-1) – Install and start live-vlm-webui systemd service.
#
# Actions:
#   1. Pre-flight: Python 3, venv, openssl, vlm-server on :8090
#   2. Create python venv at ui/.venv and install ui/requirements.txt
#   3. Enable user session linger (openshell-gateway survives SSH disconnect)
#   4. Enable jetson-stats (jtop) system service if available
#   5. Ensure TLS certificates in tls/cert.pem and tls/key.pem
#   6. (removed in Session 3-5j) config/camera.env is retired; the RTSP URL arrives as a systemd
#      credential, installed by stage 3-5j (scripts/17-camera-credential.sh)
#   7. Install /etc/systemd/system/live-vlm-webui.service
#   8. Enable, start, and verify GET https://127.0.0.1:8443/health -> 200
#
# Expects SUDO_PASS env var.
# State marker written by setup-jetson.sh: .setup-state/09_webui

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1090,SC1091
  source "${REPO_ROOT}/.env"
  set +a
fi

UI_DIR="${REPO_ROOT}/ui"
VENV_DIR="${UI_DIR}/.venv"
TLS_DIR="${REPO_ROOT}/tls"
CONFIG_DIR="${REPO_ROOT}/config"
SERVICE_NAME="live-vlm-webui"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
HTTPS_PORT="${WEBUI_PORT:-8443}"
HTTP_PORT=8091

sudocmd() { echo "${SUDO_PASS}" | sudo -S "$@"; }

echo "── Phase 2 Stage 1 (2-1): Install Live VLM WebUI Service ─────────────"

# ── 1. Pre-flight ─────────────────────────────────────────────────────────────
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required."
  exit 1
fi
if ! command -v openssl >/dev/null 2>&1; then
  echo "--> Installing openssl..."
  sudocmd apt-get update -qq && sudocmd apt-get install -y -qq openssl
fi

# ── 2. Create Python venv and install dependencies ───────────────────────────
echo "--> Setting up Python virtual environment at ${VENV_DIR}..."
if [[ ! -d "${VENV_DIR}" ]]; then
  python3 -m venv "${VENV_DIR}"
fi

echo "--> Installing WebUI dependencies from ${UI_DIR}/requirements.txt..."
"${VENV_DIR}/bin/pip" install --upgrade pip -q
"${VENV_DIR}/bin/pip" install -r "${UI_DIR}/requirements.txt" -q
echo "    Dependencies installed successfully."

# ── 3. Ensure user session linger (openshell-gateway stays up after SSH disconnect) ──
if loginctl show-user jetson --property=Linger 2>/dev/null | grep -q "Linger=yes"; then
  echo "    User session linger already enabled."
else
  sudocmd loginctl enable-linger jetson
  echo "    Enabled user session linger for jetson."
fi

# ── 4. Configure jetson-stats system service ─────────────────────────────────
if "${VENV_DIR}/bin/python3" -c "import jtop" >/dev/null 2>&1; then
  echo "--> Configuring jetson-stats (jtop) system service..."
  # Install jetson-stats service unit into systemd and ensure it is active
  sudocmd "${VENV_DIR}/bin/jtop" --install 2>/dev/null || sudocmd "${VENV_DIR}/bin/jtop" --install-service 2>/dev/null || true
  sudocmd systemctl daemon-reload
  sudocmd systemctl enable jtop.service 2>/dev/null || true
  sudocmd systemctl restart jtop.service 2>/dev/null || true
  echo "    jtop service configured."
fi

# ── 5. Generate TLS certificates for HTTPS & WebRTC ──────────────────────────
mkdir -p "${TLS_DIR}"
CERT_FILE="${TLS_DIR}/cert.pem"
KEY_FILE="${TLS_DIR}/key.pem"

if [[ ! -f "${CERT_FILE}" || ! -f "${KEY_FILE}" ]]; then
  echo "--> Generating self-signed TLS certificates for port ${HTTPS_PORT}..."
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${KEY_FILE}" \
    -out "${CERT_FILE}" \
    -days 365 \
    -subj "/CN=jetson-orin-nano.local/O=EdgeSecurityDemo" >/dev/null 2>&1
  chmod 600 "${KEY_FILE}"
  chmod 644 "${CERT_FILE}"
  echo "    TLS certificates generated."
else
  echo "    Using existing TLS certificates."
fi

# ── 6. Camera configuration ──────────────────────────────────────────────────
# Session 3-5j: no camera.env.  Without the 3-5j credential drop-in the WebUI shows the synthetic pattern.
if [[ -f "${CONFIG_DIR}/camera.env" ]]; then
  echo "    NOTE: ${CONFIG_DIR}/camera.env exists but is no longer read by ui/server.py (retired, stage 3-5j)."
fi

# ── 7. Install systemd unit ───────────────────────────────────────────────────
echo "--> Installing ${SERVICE_FILE}..."
SERVICE_SRC="${REPO_ROOT}/systemd/${SERVICE_NAME}.service"
if [[ -f "${SERVICE_SRC}" ]]; then
  sudocmd cp "${SERVICE_SRC}" "${SERVICE_FILE}"
else
  SERVICE_TMP="$(mktemp /tmp/webui-unit.XXXXXX)"
  cat > "${SERVICE_TMP}" <<UNIT
[Unit]
Description=Live VLM WebUI and Jetson Telemetry Dashboard
After=network.target vlm-server.service
Wants=vlm-server.service

[Service]
Type=simple
User=jetson
WorkingDirectory=${REPO_ROOT}
Environment=PYTHONUNBUFFERED=1
ExecStart=${VENV_DIR}/bin/python3 ui/server.py --port ${HTTPS_PORT} --redirect-port ${HTTP_PORT}
Restart=on-failure
RestartSec=5s
TimeoutStartSec=60
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
UNIT
  sudocmd cp "${SERVICE_TMP}" "${SERVICE_FILE}"
  rm -f "${SERVICE_TMP}"
fi

sudocmd chmod 644 "${SERVICE_FILE}"
sudocmd systemctl daemon-reload
sudocmd systemctl enable "${SERVICE_NAME}.service"

echo "--> Starting ${SERVICE_NAME}.service..."
sudocmd systemctl restart "${SERVICE_NAME}.service"

# ── 7. Wait for /health endpoint ─────────────────────────────────────────────
echo "--> Waiting for Live VLM WebUI on https://127.0.0.1:${HTTPS_PORT}/health..."
READY=false
for i in $(seq 1 20); do
  sleep 2
  CODE=$(curl -k -s -o /dev/null -w "%{http_code}" \
    "https://127.0.0.1:${HTTPS_PORT}/health" 2>/dev/null || echo "000")
  if [[ "${CODE}" == "200" ]]; then
    READY=true
    echo "    WebUI health → 200 OK (after $((i * 2)) s)"
    break
  fi
  echo "    ... waiting (${i}/20, last HTTP ${CODE})"
done

if [[ "${READY}" != "true" ]]; then
  echo
  echo "ERROR: ${SERVICE_NAME} did not start properly."
  echo "       Logs: journalctl -u ${SERVICE_NAME} -n 40 --no-pager"
  sudocmd journalctl -u "${SERVICE_NAME}" -n 40 --no-pager || true
  exit 1
fi

echo
echo "── Phase 2 Stage 1 (2-1) Complete ──────────────────────────────────────"
echo "    Live VLM WebUI is active and listening:"
echo "    HTTPS WebUI    : https://<jetson-ip>:${HTTPS_PORT}/"
echo "    HTTP Redirect  : http://<jetson-ip>:${HTTP_PORT}/"
echo "    Telemetry WS   : wss://<jetson-ip>:${HTTPS_PORT}/ws/telemetry"
echo "    Video Feed     : https://<jetson-ip>:${HTTPS_PORT}/video_feed"
