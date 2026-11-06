#!/usr/bin/env bash
# vault/gen-tls.sh   (runs ON THE MAC control plane, in ~/edge-device-demo)
#
# Session 7-2e - self-signed Vault TLS certificate, SANs taken from .env.
#
#   SANs:  IP:${MAC_IP}, IP:127.0.0.1, DNS:${MAC_HOSTNAME}, DNS:vault, DNS:localhost
#   Files: tls/vault.key  (RSA 4096, mode 0600 - NEVER printed, copied, rsynced or committed)
#          tls/vault.crt  (self-signed, 10 years, CN=vault - public; this one file is distributed to the Jetson)
#
# Why create-if-missing: the self-signed cert IS the CA bundle on every consumer (vault-agent configs of
# stages 5-1/5-1b, the trusted-edge copy, the OpenShell gateway ca_bundle of stage 3-5h, VAULT_CACERT).
# Replacing it breaks all of them until the new tls/vault.crt reaches the Jetson and those stages re-run.
# So an existing, matching key+cert pair is left alone (the SANs are only checked and reported).
# Regenerate on purpose with:  bash vault/gen-tls.sh --force
#
# Usage on the Mac:   bash vault/gen-tls.sh [--force]        (or: make gen-tls)
#
# Docs (documented, read 2026-11-03):
#   Vault TCP listener tls_cert_file / tls_key_file (PEM; reloaded on SIGHUP or with tls_reload_interval):
#     https://developer.hashicorp.com/vault/docs/configuration/listener/tcp
#   openssl req -config / x509_extensions (subjectAltName in a config file works on OpenSSL 3 and LibreSSL):
#     https://docs.openssl.org/3.0/man1/openssl-req/
# The Mac ships LibreSSL 3.3.6 (read over SSH, 2026-11-03). `req -addext` is therefore NOT used; the SANs go
# through a temporary config file. That this exact command works on LibreSSL is *unverified* until this script
# has been run on the Mac - the read-back checks below stop it with an error if the result is wrong.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
cd "$(dirname "${BASH_SOURCE[0]}")/.."

ok()   { echo "  ✓ $*"; }
info() { echo "  ▷ $*"; }
warn() { echo "  ⚠ $*"; }
err()  { echo "  ✗ $*" >&2; exit 1; }

FORCE=false
for a in "$@"; do
  case "${a}" in
    --force) FORCE=true ;;
    *) err "unknown argument '${a}' (only --force)" ;;
  esac
done

[[ -f .env ]] || err ".env not found in $(pwd)"
set -a
# shellcheck disable=SC1091
source .env
set +a
: "${MAC_IP:?set MAC_IP in .env}"
: "${MAC_HOSTNAME:?set MAC_HOSTNAME in .env}"
[[ "${MAC_IP}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || err "MAC_IP='${MAC_IP}' is not an IPv4 address"
[[ "${MAC_HOSTNAME}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || err "MAC_HOSTNAME='${MAC_HOSTNAME}' is not a valid DNS name"
command -v openssl >/dev/null || err "openssl not found"

# ── wanted SAN list (deduplicated, order kept) ────────────────────────────────
WANT_IPS=("${MAC_IP}")
[[ "${MAC_IP}" != "127.0.0.1" ]] && WANT_IPS+=("127.0.0.1")
WANT_DNS=()
for d in "${MAC_HOSTNAME}" vault localhost; do
  dup=false
  for e in "${WANT_DNS[@]:-}"; do [[ "${e}" == "${d}" ]] && dup=true; done
  ${dup} || WANT_DNS+=("${d}")
done

san_text() { openssl x509 -in "$1" -noout -text | grep -A1 'Subject Alternative Name' | tail -1; }
pub_hash_cert() { openssl x509 -in tls/vault.crt -noout -pubkey | shasum -a 256 | cut -d' ' -f1; }
pub_hash_key()  { openssl pkey -in tls/vault.key -pubout 2>/dev/null | shasum -a 256 | cut -d' ' -f1; }

# Read the SANs back and compare with the wanted list. Prints one line per name; returns 1 if any is missing.
check_sans() {
  local file="$1" text missing=0 n
  text="$(san_text "${file}"),"          # trailing comma so every entry is "<type>:<value>," (fixed-string match, BSD/GNU grep alike)
  for n in "${WANT_IPS[@]}"; do
    if grep -qF "IP Address:${n}," <<<"${text}"; then ok "SAN IP:${n} present"; else warn "SAN IP:${n} MISSING"; missing=1; fi
  done
  for n in "${WANT_DNS[@]}"; do
    if grep -qF "DNS:${n}," <<<"${text}"; then ok "SAN DNS:${n} present"; else warn "SAN DNS:${n} MISSING"; missing=1; fi
  done
  return "${missing}"
}

mkdir -p tls

# ── existing pair ────────────────────────────────────────────────────────────
if [[ "${FORCE}" != "true" && -f tls/vault.crt && -f tls/vault.key ]]; then
  echo "── existing tls/vault.crt + tls/vault.key found (not regenerating; use --force to replace) ──"
  [[ "$(pub_hash_cert)" == "$(pub_hash_key)" ]] \
    || err "tls/vault.key does not match tls/vault.crt (public-key hashes differ). Fix by hand or run --force (then redistribute the cert)."
  ok "private key matches the certificate (public-key SHA-256 equal; neither printed)"
  openssl x509 -in tls/vault.crt -noout -subject -enddate | sed 's/^/    /'
  if openssl x509 -in tls/vault.crt -noout -checkend 2592000 >/dev/null; then ok "valid for more than 30 more days"; else warn "expires within 30 days"; fi
  if check_sans tls/vault.crt; then
    ok "SANs cover everything wanted from .env"
  else
    warn "the existing certificate lacks SANs listed above. Clients that use only the missing name will fail verification."
    warn "Replacing it (--force) changes the CA bundle everywhere: re-run bootstrap so the Jetson gets the new tls/vault.crt,"
    warn "then re-run stages 5-1, 5-1b, 3-5g, 3-5h (they copy/reference the cert)."
  fi
  chmod 600 tls/vault.key
  exit 0
fi

if [[ "${FORCE}" != "true" && ( -f tls/vault.crt || -f tls/vault.key ) ]]; then
  err "only one of tls/vault.crt / tls/vault.key exists - refusing to guess. Inspect tls/, or run with --force."
fi

# ── generate ─────────────────────────────────────────────────────────────────
echo "── generating a new self-signed certificate ──"
TS="$(date +%Y%m%d-%H%M%S)"
if [[ -f tls/vault.key || -f tls/vault.crt ]]; then
  # .scratch/ is git-ignored (.gitignore) and excluded from every rsync in this repo, so a backed-up PRIVATE key
  # can neither be committed nor leave the Mac by the sync scripts. (tls/ itself is mounted into the Vault container.)
  BK=".scratch/tls-backups/${TS}"
  mkdir -p "${BK}"; chmod 700 .scratch "${BK}" 2>/dev/null || true
  warn "--force: replacing the existing pair. Backups in ${BK}/ (git-ignored, not rsynced)"
  [[ -f tls/vault.key ]] && { cp -p tls/vault.key "${BK}/vault.key"; chmod 600 "${BK}/vault.key"; }
  [[ -f tls/vault.crt ]] && cp -p tls/vault.crt "${BK}/vault.crt"
fi

CONF="$(mktemp)"
NEW_KEY="$(mktemp)"
NEW_CRT="$(mktemp)"
trap 'rm -f "${CONF}" "${NEW_KEY}" "${NEW_CRT}"' EXIT
{
  echo "[req]"
  echo "distinguished_name = dn"
  echo "x509_extensions = v3"
  echo "prompt = no"
  echo "[dn]"
  echo "CN = vault"
  echo "[v3]"
  echo "subjectAltName = @alt"
  echo "basicConstraints = critical,CA:FALSE"
  echo "keyUsage = critical,digitalSignature,keyEncipherment"
  echo "extendedKeyUsage = serverAuth,clientAuth"
  echo "[alt]"
  i=0; for n in "${WANT_IPS[@]}"; do i=$((i + 1)); echo "IP.${i} = ${n}"; done
  i=0; for n in "${WANT_DNS[@]}"; do i=$((i + 1)); echo "DNS.${i} = ${n}"; done
} > "${CONF}"

umask 077
openssl req -x509 -newkey rsa:4096 -nodes -sha256 -days 3650 \
  -keyout "${NEW_KEY}" -out "${NEW_CRT}" -config "${CONF}" >/dev/null 2>&1 \
  || err "openssl req failed (run it by hand to see the message; the key was not written to tls/)"

# verify BEFORE installing: SANs and key/cert match
check_sans "${NEW_CRT}" || err "generated certificate does not carry all wanted SANs - not installed"
[[ "$(openssl x509 -in "${NEW_CRT}" -noout -pubkey | shasum -a 256 | cut -d' ' -f1)" == \
   "$(openssl pkey -in "${NEW_KEY}" -pubout 2>/dev/null | shasum -a 256 | cut -d' ' -f1)" ]] \
  || err "generated key does not match the generated certificate - not installed"
ok "SANs and key/cert pairing verified before install"

install -m 600 "${NEW_KEY}" tls/vault.key
install -m 644 "${NEW_CRT}" tls/vault.crt
[[ "$(stat -f '%Lp' tls/vault.key 2>/dev/null || stat -c '%a' tls/vault.key)" == "600" ]] || err "tls/vault.key is not mode 600"
ok "installed tls/vault.key (0600, stays on this Mac) and tls/vault.crt (public)"
openssl x509 -in tls/vault.crt -noout -subject -dates -fingerprint -sha256 | sed 's/^/    /'

# ── make a running Vault pick it up (SIGHUP reloads the listener cert) ─────────
DOCKER=/usr/local/bin/docker
if [[ -x "${DOCKER}" ]] && "${DOCKER}" ps --format '{{.Names}}' 2>/dev/null | grep -qx vault; then
  "${DOCKER}" kill -s HUP vault >/dev/null && ok "SIGHUP sent to the running vault container"
  sleep 3
  PORT="${VAULT_PORT:-8200}"
  SERVED="$(echo | openssl s_client -connect "127.0.0.1:${PORT}" 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null || true)"
  DISK="$(openssl x509 -in tls/vault.crt -noout -fingerprint -sha256)"
  if [[ -n "${SERVED}" && "${SERVED}" == "${DISK}" ]]; then
    ok "Vault now serves the new certificate (fingerprint equal)"
  else
    warn "Vault is NOT serving the new certificate yet (served='${SERVED:-none}'). Restart it: make down-mac && make up-mac, then 'make setup-vault' to unseal."
  fi
else
  info "no running vault container: it will read the new certificate on its next start"
fi

echo
warn "NEXT: tls/vault.crt changed. The Jetson copy, vault-agent configs and the gateway ca_bundle still hold the OLD certificate."
warn "      Run ./scripts/bootstrap-mac.sh (copies the cert to the workstation) and then re-run Jetson stages 5-1, 5-1b, 3-5g, 3-5h."
