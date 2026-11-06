#!/usr/bin/env bash
# scripts/bootstrap-mac.sh   (runs on the WORKSTATION; every Mac command goes over SSH, AGENTS.md section 1.1)
#
# Session 7-2e - the Mac control-plane counterpart of bootstrap-jetson.sh.
#
#   ./scripts/bootstrap-mac.sh                       # all steps, in order
#   ./scripts/bootstrap-mac.sh --only-step tpm,roles # only these steps (canonical order is kept)
#   ./scripts/bootstrap-mac.sh --force-tls           # gen-tls.sh --force (REPLACES the Vault cert; see vault/gen-tls.sh)
#   ./scripts/bootstrap-mac.sh --reset-mac           # FULL WIPE of the Mac control plane, then stops (see below)
#   ./scripts/bootstrap-mac.sh --list
#
# Steps (each ends with a check of OBSERVABLE state; a check that could not run says "not run"):
#   sync    rsync the repo to <user>@MAC_IP:~/edge-device-demo (NO --delete; never touches tls/, .env, .vault-keys.json,
#           .mac-resume.log, vault/logs/)                       check: key files present on the Mac
#   env     push the workstation .env (0600) and validate it    check: sha-256 equal on both sides, required keys set
#   tls     vault/gen-tls.sh on the Mac (create-if-missing; SANs from .env)   check: SAN + key/cert read-back (in the script)
#   cert    copy the PUBLIC tls/vault.crt back to the workstation so bootstrap-jetson.sh distributes it
#                                                               check: fingerprint equal on both sides
#   up      make up-mac                                         check: postgres pg_isready; Vault answers TLS with a cert
#                                                               whose fingerprint equals tls/vault.crt
#   vault   make setup-vault (init, unseal, engines, policies, AppRole; rotates the Postgres superuser password once)
#                                                               check: unsealed; .vault-keys.json present; engines + policy listed
#   tpm     make setup-tpm-auth (needs the Jetson reachable from the Mac and tpm2_createek there)
#                                                               check: auth/tpm enabled; role edge-camera-agent readable
#   roles   make setup-roles                                    check: role openshell-gateway readable; mount edge-ai-demo-gateway/ listed
#   reader  make setup-control-reader                           check: control_plane_reader in .vault-keys.json; proofs RAN or "NOT RUN"
#   resume  make install-mac-resume                             check: plist lints; launchctl print (if it cannot run: "not verified")
#
# --reset-mac (Session 7-2e, user decision: "full wipe"): lists what it will delete, asks for a typed RESET, then on the Mac:
#   `docker compose down -v` (removes the containers and the named volumes edge-device-demo_vault-data and
#   edge-device-demo_postgres-data - documented: https://docs.docker.com/reference/cli/docker/compose/down/), and deletes
#   ~/edge-device-demo/.vault-keys.json, tls/vault.crt, tls/vault.key. ALL Vault state and ALL stored events are lost
#   (the Transit key goes with the Vault volume, so old ciphertext could never be decrypted anyway). It then verifies
#   (volumes + files absent) and STOPS; it does not rebuild. Kept: .env, vault/logs/audit.log, .mac-resume.log, the
#   LaunchAgent, the workstation copy of tls/vault.crt (step `cert` replaces it on the next run).
#   Fresh-start order: (1) bootstrap-jetson.sh <ip> --reset-all --no-run   [needs the OLD Vault up],
#                      (2) bootstrap-mac.sh --reset-mac,   (3) install-all.sh.   Agents never run any of these.
#
# The Vault private key tls/vault.key never leaves the Mac: it is created there, excluded from rsync, and no step reads it
# off the Mac. .vault-keys.json (root token, unseal key) is also never copied; only role_id/secret_id of the
# control-plane-reader leave the Mac later, via bootstrap-jetson.sh stage 5-3b (unchanged).
#
# Not done here (out of scope, say so when asked): first-time `authorized_keys` for the workstation on a fresh Jetson
# and for the Mac's key on the Jetson (setup-tpm-auth.sh stops with a clear message); Docker Desktop and Homebrew `vault`
# on a fresh Mac; FileVault/auto-login.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

ok()   { echo "  ✓ $*"; }
info() { echo "  ▷ $*"; }
warn() { echo "  ⚠ $*"; }
err()  { echo "  ✗ $*" >&2; exit 1; }
sep()  { echo; echo "════ $* ════════════════════════════════════════════════"; }

ALL_STEPS=(sync env tls cert up vault tpm roles reader resume)
ONLY=""
FORCE_TLS=false
RESET_MAC=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset-mac)   RESET_MAC=true; shift ;;
    --only-step)   ONLY="$2"; shift 2 ;;
    --only-step=*) ONLY="${1#--only-step=}"; shift ;;
    --force-tls)   FORCE_TLS=true; shift ;;
    --list)        printf '%s\n' "${ALL_STEPS[@]}"; exit 0 ;;
    *)             err "unknown argument '$1' (see the header of this script)" ;;
  esac
done
if ${RESET_MAC} && { [[ -n "${ONLY}" ]] || ${FORCE_TLS}; }; then
  err "--reset-mac cannot be combined with --only-step or --force-tls"
fi

# ── .env on the workstation ──────────────────────────────────────────────────
[[ -f .env ]] || err ".env not found in ${REPO_ROOT} (cp .env.example .env and fill it in)"
set -a
# shellcheck disable=SC1091
source .env
set +a

REQUIRED=(MAC_IP MAC_USER MAC_HOSTNAME MAC_SSH_KEY JETSON_IP JETSON_USER JETSON_SSH_KEY VAULT_PORT VAULT_ADDR
          POSTGRES_PORT POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD CAMERA_RTSP_URL)

validate_env() {
  local v
  for v in "${REQUIRED[@]}"; do [[ -n "${!v:-}" ]] || err "required .env key '${v}' is missing or empty"; done
  if [[ -z "${VAULT_LICENSE_STRING:-${VAULT_LICENSE:-}}" ]]; then
    if [[ -n "${VAULT_LICENSE_PATH:-}" ]]; then
      err "only VAULT_LICENSE_PATH is set: docker-compose.yml does not mount a licence file (documented in its comment). Put the licence text in VAULT_LICENSE_STRING."
    fi
    err "no Vault Enterprise licence: set VAULT_LICENSE_STRING in .env"
  fi
  [[ -n "${VAULT_LICENSE_STRING:-}" && -n "${VAULT_LICENSE_PATH:-}" ]] && err "both VAULT_LICENSE_STRING and VAULT_LICENSE_PATH are set; use one"
  [[ "${MAC_IP}" == 192.0.2.* ]] && err "MAC_IP='${MAC_IP}' is an RFC 5737 documentation address (still the .env.example value)"
  [[ "${POSTGRES_PASSWORD}" == "postgres_password_here" ]] && err "POSTGRES_PASSWORD is still the .env.example placeholder"
  [[ "${CAMERA_RTSP_URL}" == *"@192.0.2."* ]] && err "CAMERA_RTSP_URL still points at the RFC 5737 documentation address"
  local vhost="${VAULT_ADDR#*://}"; vhost="${vhost%%[:/]*}"
  case "${vhost}" in
    "${MAC_IP}"|"${MAC_HOSTNAME}"|127.0.0.1|localhost|vault) ;;
    *) err "VAULT_ADDR host '${vhost}' is not one of the certificate SANs (MAC_IP, MAC_HOSTNAME, 127.0.0.1, localhost, vault)" ;;
  esac
  ok ".env: all required keys set, no placeholders, VAULT_ADDR host '${vhost}' is covered by the SANs"
}

# ── SSH to the Mac ───────────────────────────────────────────────────────────
MAC_KEY="${MAC_SSH_KEY/#\~/$HOME}"
MAC="${MAC_USER}@${MAC_IP}"
[[ -f "${MAC_KEY}" ]] || err "SSH key ${MAC_KEY} not found"
SOCK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mac-ssh.XXXXXX")"
SSH_OPTS=(-i "${MAC_KEY}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o BatchMode=yes
          -o ServerAliveInterval=15 -o ControlMaster=auto -o "ControlPath=${SOCK_DIR}/ctl" -o ControlPersist=300)

STEP_LOG=()
CURRENT=""
RESET_RESULT=""
summary() {
  local rc=$?
  ssh -O exit -o "ControlPath=${SOCK_DIR}/ctl" "${MAC}" 2>/dev/null || true
  rm -rf "${SOCK_DIR}"
  [[ -n "${CURRENT}" ]] && STEP_LOG+=("${CURRENT}|FAIL")
  echo
  if ${RESET_MAC}; then
    echo "════════════ bootstrap-mac --reset-mac (exit ${rc}) ════════════"
    echo "  reset-mac  ${RESET_RESULT:-not run}"
    echo "  (no other step ran; the Mac is NOT rebuilt - next: ./scripts/install-all.sh)"
    exit "${rc}"
  fi
  echo "════════════ bootstrap-mac summary (exit ${rc}) ════════════"
  local s e found
  for s in "${ALL_STEPS[@]}"; do
    found="not run"
    [[ -n "${ONLY}" && ",${ONLY}," != *",${s},"* ]] && found="not selected"
    for e in "${STEP_LOG[@]:-}"; do [[ "${e%%|*}" == "${s}" ]] && found="${e#*|}"; done
    printf '  %-8s %s\n' "${s}" "${found}"
  done
  echo "═════════════════════════════════════════════════════════"
  exit "${rc}"
}
trap summary EXIT

# run a command on the Mac in the repo dir with Homebrew/Docker on PATH
mac() { ssh "${SSH_OPTS[@]}" "${MAC}" "export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH; cd ~/edge-device-demo && $1"; }
# same, but without cd (before the repo exists)
mac_raw() { ssh "${SSH_OPTS[@]}" "${MAC}" "$1"; }
# Vault CLI on the Mac with the root token read inside the Mac shell (never in argv, never printed)
mac_vault() {
  mac "export VAULT_ADDR=https://127.0.0.1:${VAULT_PORT} VAULT_CACERT=tls/vault.crt; \
       VAULT_TOKEN=\$(python3 -c \"import json;print(json.load(open('.vault-keys.json'))['root_token'])\") && export VAULT_TOKEN && $1"
}

want() { [[ -z "${ONLY}" || ",${ONLY}," == *",$1,"* ]]; }
done_step() { STEP_LOG+=("$1|$2"); CURRENT=""; }

# ── preflight (always) ───────────────────────────────────────────────────────
sep "preflight"
validate_env
if [[ -n "${ONLY}" ]]; then
  IFS=',' read -ra _sel <<<"${ONLY}"
  for s in "${_sel[@]}"; do
    [[ " ${ALL_STEPS[*]} " == *" ${s} "* ]] || err "unknown step '${s}' (valid: ${ALL_STEPS[*]})"
  done
fi
mac_raw "echo reachable >/dev/null" || err "cannot SSH to ${MAC} with ${MAC_KEY} (Mac asleep, wrong network, or key not authorised)"
ok "SSH to ${MAC} works"
mac_raw "[ -x /usr/local/bin/docker ]" || warn "/usr/local/bin/docker not found on the Mac (Docker Desktop installed?)"

# ── --reset-mac: full wipe of the Mac control plane, then stop ───────────────
# Documented: `docker compose down -v` removes the containers and the named volumes declared in the compose file
# (https://docs.docker.com/reference/cli/docker/compose/down/). Volumes on this Mac (read-only `docker volume ls`,
# 2026-11-04): edge-device-demo_vault-data, edge-device-demo_postgres-data. Nothing here has been run yet.
if ${RESET_MAC}; then
  CURRENT=reset-mac; RESET_RESULT="FAIL"; sep "reset-mac (FULL WIPE of ${MAC})"
  mac "/usr/local/bin/docker info >/dev/null 2>&1" || err "Docker daemon not reachable on the Mac (start Docker Desktop)"
  echo "  This will DELETE on ${MAC}:"
  echo "    - containers vault + postgres and the Docker volumes edge-device-demo_vault-data, edge-device-demo_postgres-data"
  echo "      (ALL Vault state incl. the Transit key, AppRole/TPM config, KV; ALL stored events in PostgreSQL)"
  echo "    - ~/edge-device-demo/.vault-keys.json   (root token, unseal key, AppRole ids)"
  echo "    - ~/edge-device-demo/tls/vault.crt and tls/vault.key   (a new pair is generated by step tls)"
  echo "  Kept: .env, vault/logs/audit.log, .mac-resume.log, the LaunchAgent, the workstation copy of tls/vault.crt."
  echo "  Present now (read-only):"
  mac "/usr/local/bin/docker volume ls --format '{{.Name}}' | grep -E '^edge-device-demo_(vault|postgres)-data\$' | sed 's/^/    volume: /'; \
       ls -1 .vault-keys.json tls/vault.crt tls/vault.key 2>/dev/null | sed 's/^/    file:   /'" || true
  echo "  The Jetson keeps its markers and its copy of the old certificate: run"
  echo "    ./scripts/bootstrap-jetson.sh ${JETSON_IP} --reset-all --no-run   BEFORE this (it needs the OLD Vault)."
  echo "  If the Mac is logged in while it is wiped, the mac-resume LaunchAgent may start at the next login and fail until step vault has run."
  echo
  read -rp "Type RESET to wipe the Mac control plane (anything else aborts): " _ANS
  [[ "${_ANS}" == "RESET" ]] || { RESET_RESULT="aborted by user; nothing changed"; CURRENT=""; echo "Aborted; nothing changed."; exit 1; }

  mac "/usr/local/bin/docker compose -f docker-compose.yml down -v" || err "docker compose down -v failed; files NOT deleted"
  mac "rm -f .vault-keys.json tls/vault.crt tls/vault.key"
  # verify observable state
  LEFT="$(mac "/usr/local/bin/docker volume ls --format '{{.Name}}' | grep -E '^edge-device-demo_(vault|postgres)-data\$' || true")"
  [[ -z "${LEFT}" ]] || err "volumes still present after down -v: ${LEFT}"
  CONT="$(mac "/usr/local/bin/docker ps -a --format '{{.Names}}' | grep -E '^(vault|postgres)\$' || true")"
  [[ -z "${CONT}" ]] || err "containers still present after down -v: ${CONT}"
  mac "! test -e .vault-keys.json && ! test -e tls/vault.crt && ! test -e tls/vault.key" || err "key/cert files still present on the Mac"
  ok "verified on the Mac: both volumes, both containers, .vault-keys.json, tls/vault.crt and tls/vault.key are gone"
  warn "NOT checked: that no other Docker volume held Vault/PostgreSQL data (only the two compose-declared volumes are removed)"
  RESET_RESULT="RUN-OK (wipe verified; nothing rebuilt)"; CURRENT=""
  echo
  echo "==> Mac wiped. Next: ./scripts/install-all.sh   (tls generates a NEW pair; the Jetson must then re-trust it: install-all runs the Jetson in default order from reset markers)"
  exit 0
fi

# ── sync ─────────────────────────────────────────────────────────────────────
if want sync; then
  CURRENT=sync; sep "sync"
  mac_raw "mkdir -p ~/edge-device-demo"
  # Mac-owned state is excluded (so it is neither overwritten nor read): tls/ (key + cert authority), .env (pushed in step env),
  # .vault-keys.json, logs. No --delete: stale files from older syncs stay; they are harmless and not removed behind your back.
  rsync -az -e "ssh ${SSH_OPTS[*]}" \
    --exclude='/.git/' --exclude='/.bob/' --exclude='/.vscode/' --exclude='.DS_Store' --exclude='*.pyc' --exclude='__pycache__/' \
    --exclude='.venv/' --exclude='node_modules/' --exclude='/external/' --exclude='/checkpoints/' --exclude='/engines/' \
    --exclude='/models/' --exclude='/data/' --exclude='/source/' --exclude='/.scratch/' --exclude='/config/camera.env' \
    --exclude='/tls/' --exclude='/.env' --exclude='/.vault-keys.json' --exclude='/.mac-resume.log' --exclude='/vault/logs/' \
    --exclude='/.setup-state/' \
    ./ "${MAC}:~/edge-device-demo/"
  mac "test -f Makefile && test -f docker-compose.yml && test -f vault/gen-tls.sh && test -f vault/init-vault.sh && test -f vault/schema.sql" \
    || err "key files missing on the Mac after rsync"
  # a file we changed locally must now be identical on the Mac
  L="$(shasum -a 256 vault/gen-tls.sh | cut -d' ' -f1)"
  R="$(mac "shasum -a 256 vault/gen-tls.sh" | cut -d' ' -f1)"
  [[ "${L}" == "${R}" ]] || err "vault/gen-tls.sh differs between workstation and Mac after rsync"
  ok "repo synced; vault/gen-tls.sh identical on both sides (sha-256 ${L:0:12})"
  done_step sync RUN-OK
fi

# ── env ──────────────────────────────────────────────────────────────────────
if want env; then
  CURRENT=env; sep "env"
  rsync -az -e "ssh ${SSH_OPTS[*]}" .env "${MAC}:~/edge-device-demo/.env"
  mac "chmod 600 .env"
  L="$(shasum -a 256 .env | cut -d' ' -f1)"
  R="$(mac "shasum -a 256 .env" | cut -d' ' -f1)"
  [[ "${L}" == "${R}" ]] || err ".env differs between workstation and Mac after the push"
  [[ "$(mac "stat -f '%Lp' .env")" == "600" ]] || err "Mac .env is not mode 600"
  ok ".env pushed to the Mac (0600); sha-256 equal on both sides (${L:0:12}); the Mac needs the licence, DB password and camera URL (Vault seed)"
  done_step env RUN-OK
fi

# ── tls ──────────────────────────────────────────────────────────────────────
if want tls; then
  CURRENT=tls; sep "tls (vault/gen-tls.sh on the Mac)"
  mac "bash vault/gen-tls.sh$( ${FORCE_TLS} && echo ' --force')"
  mac "test \"\$(stat -f '%Lp' tls/vault.key)\" = 600" || err "tls/vault.key on the Mac is not mode 600"
  ok "tls/vault.key mode 600 on the Mac (the key was not read or copied by this script)"
  done_step tls RUN-OK
fi

# ── cert (public part back to the workstation) ───────────────────────────────
if want cert; then
  CURRENT=cert; sep "cert (public tls/vault.crt -> workstation)"
  mkdir -p tls
  TMP_CRT="$(mktemp)"
  scp "${SSH_OPTS[@]}" "${MAC}:~/edge-device-demo/tls/vault.crt" "${TMP_CRT}" >/dev/null
  openssl x509 -in "${TMP_CRT}" -noout >/dev/null 2>&1 || { rm -f "${TMP_CRT}"; err "fetched tls/vault.crt is not a certificate"; }
  FP_L="$(openssl x509 -in "${TMP_CRT}" -noout -fingerprint -sha256)"
  FP_R="$(mac "openssl x509 -in tls/vault.crt -noout -fingerprint -sha256")"
  [[ "${FP_L}" == "${FP_R}" ]] || { rm -f "${TMP_CRT}"; err "fingerprint of the fetched cert differs from the Mac's file"; }
  if [[ -f tls/vault.crt ]] && ! cmp -s tls/vault.crt "${TMP_CRT}"; then
    warn "workstation tls/vault.crt differed from the Mac's; replacing it (tracked in git: 'git status' will show it modified - your call whether to commit)"
    warn "the Jetson still trusts the OLD cert until bootstrap-jetson.sh re-copies it and stages 5-1, 5-1b, 3-5g, 3-5h re-run"
  fi
  install -m 644 "${TMP_CRT}" tls/vault.crt; rm -f "${TMP_CRT}"
  ok "workstation tls/vault.crt = the Mac's (${FP_R#*=}); only the public cert was copied"
  done_step cert RUN-OK
fi

# ── up ───────────────────────────────────────────────────────────────────────
if want up; then
  CURRENT=up; sep "up (make up-mac)"
  mac "/usr/local/bin/docker info >/dev/null 2>&1" || err "Docker daemon not reachable on the Mac (start Docker Desktop)"
  mac "make up-mac"
  mac "/usr/local/bin/docker exec postgres sh -c 'pg_isready -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\"'" >/dev/null \
    || err "PostgreSQL does not answer pg_isready"
  ok "PostgreSQL answers pg_isready"
  # Vault: TLS answer + served cert equals the file (a SIGHUP/restart may be needed after a regenerated cert)
  for _ in $(seq 1 20); do
    mac "curl -s -o /dev/null --cacert tls/vault.crt --max-time 4 'https://127.0.0.1:${VAULT_PORT}/v1/sys/health?uninitcode=200&sealedcode=200'" && break
    sleep 2
  done
  mac "curl -s --cacert tls/vault.crt --max-time 4 'https://127.0.0.1:${VAULT_PORT}/v1/sys/health?uninitcode=200&sealedcode=200' | grep -q initialized" \
    || err "Vault does not answer over TLS with tls/vault.crt as CA (container logs: docker logs vault)"
  SERVED="$(mac "echo | openssl s_client -connect 127.0.0.1:${VAULT_PORT} 2>/dev/null | openssl x509 -noout -fingerprint -sha256")"
  DISK="$(mac "openssl x509 -in tls/vault.crt -noout -fingerprint -sha256")"
  [[ -n "${SERVED}" && "${SERVED}" == "${DISK}" ]] \
    || err "Vault serves a certificate that is not tls/vault.crt (served='${SERVED:-none}'): restart it (make down-mac && make up-mac)"
  ok "Vault answers over TLS and serves the certificate in tls/vault.crt (fingerprint equal)"
  done_step up RUN-OK
fi

# ── vault ────────────────────────────────────────────────────────────────────
if want vault; then
  CURRENT=vault; sep "vault (make setup-vault)"
  mac "make setup-vault"
  mac "test -s .vault-keys.json && test \"\$(stat -f '%Lp' .vault-keys.json)\" = 600" || err ".vault-keys.json missing or not mode 600 on the Mac"
  mac_vault "vault status -format=json | python3 -c \"import json,sys; s=json.load(sys.stdin); sys.exit(0 if s['initialized'] and not s['sealed'] else 1)\"" \
    || err "Vault is not initialised+unsealed after setup-vault"
  ok "Vault initialised and unsealed; .vault-keys.json present (0600)"
  mac_vault "vault secrets list -format=json | python3 -c \"
import json,sys; m=json.load(sys.stdin)
need=['edge-ai-demo-database/','edge-ai-demo-encryption-transit/','edge-ai-demo-kv/']
miss=[n for n in need if n not in m]; print('missing mounts:',miss) if miss else None; sys.exit(1 if miss else 0)\"" \
    || err "expected secrets engines are not all mounted"
  mac_vault "vault policy read edge-ai-demo-policy-edge >/dev/null" || err "policy edge-ai-demo-policy-edge not found"
  ok "engines edge-ai-demo-database/, -encryption-transit/, -kv/ mounted; policy edge-ai-demo-policy-edge exists"
  done_step vault RUN-OK
fi

# ── tpm ──────────────────────────────────────────────────────────────────────
if want tpm; then
  CURRENT=tpm; sep "tpm (make setup-tpm-auth)"
  info "needs: Jetson reachable from the Mac with JETSON_SSH_KEY, and tpm2_createek on the Jetson (stage 1-1 installs tpm2-tools)"
  mac "make setup-tpm-auth"
  mac_vault "vault auth list -format=json | python3 -c \"import json,sys; sys.exit(0 if 'tpm/' in json.load(sys.stdin) else 1)\"" || err "auth/tpm is not enabled"
  mac_vault "vault read auth/tpm/role/edge-camera-agent >/dev/null" || err "auth/tpm/role/edge-camera-agent not readable"
  ok "auth/tpm enabled; role edge-camera-agent exists"
  done_step tpm RUN-OK
fi

# ── roles ────────────────────────────────────────────────────────────────────
if want roles; then
  CURRENT=roles; sep "roles (make setup-roles)"
  mac "make setup-roles"
  mac_vault "vault read auth/tpm/role/openshell-gateway >/dev/null" || err "auth/tpm/role/openshell-gateway not readable"
  mac_vault "vault secrets list -format=json | python3 -c \"import json,sys; sys.exit(0 if 'edge-ai-demo-gateway/' in json.load(sys.stdin) else 1)\"" \
    || err "mount edge-ai-demo-gateway/ not found"
  ok "role openshell-gateway exists; mount edge-ai-demo-gateway/ listed"
  done_step roles RUN-OK
fi

# ── reader ───────────────────────────────────────────────────────────────────
if want reader; then
  CURRENT=reader; sep "reader (make setup-control-reader)"
  RDR_OUT="$(mktemp)"
  mac "make setup-control-reader" | tee "${RDR_OUT}"
  mac "python3 -c \"import json,sys; d=json.load(open('.vault-keys.json')).get('control_plane_reader') or {}; sys.exit(0 if d.get('role_id') and d.get('secret_id') else 1)\"" \
    || { rm -f "${RDR_OUT}"; err "control_plane_reader role_id/secret_id missing in .vault-keys.json"; }
  ok "control_plane_reader role_id/secret_id present in the Mac's .vault-keys.json"
  if grep -q "NOT RUN: narrowness proofs" "${RDR_OUT}"; then
    warn "narrowness proofs NOT RUN (no stored events yet). Run 'make setup-control-reader' on the Mac after the Jetson pipeline has written rows."
    done_step reader "RUN-OK (role created; proofs not run)"
  else
    ok "narrowness proofs ran (see output above)"
    done_step reader "RUN-OK (proofs ran)"
  fi
  rm -f "${RDR_OUT}"
fi

# ── resume ───────────────────────────────────────────────────────────────────
if want resume; then
  CURRENT=resume; sep "resume (make install-mac-resume)"
  mac "make install-mac-resume"
  mac "plutil -lint \$HOME/Library/LaunchAgents/com.edge-demo.mac-resume.plist >/dev/null" || err "LaunchAgent plist missing or invalid"
  ok "LaunchAgent plist exists and lints"
  if mac "launchctl print gui/\$(id -u)/com.edge-demo.mac-resume >/dev/null 2>&1"; then
    ok "launchctl print: com.edge-demo.mac-resume is loaded"
    done_step resume RUN-OK
  else
    warn "launchctl print failed over SSH (no GUI session?): load state NOT VERIFIED. A real reboot/login test is still *unverified* (AGENTS.md section 3)."
    done_step resume "RUN-OK (load state not verified)"
  fi
fi

echo
echo "==> bootstrap-mac done. Next: ./scripts/bootstrap-jetson.sh ${JETSON_IP}   (or ./scripts/install-all.sh for the whole chain)"
