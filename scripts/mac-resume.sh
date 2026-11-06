#!/usr/bin/env bash
# scripts/mac-resume.sh — bring the Mac control plane back after a Mac reboot / login.
#
# Why: Docker restarts the vault and postgres containers on its own (restart: unless-stopped),
# but Vault comes back SEALED (Shamir, 1 share).  While it is sealed nobody can mint database
# credentials, so trusted-edge on the Jetson cannot write.  `make setup-vault` unseals it
# (key from .vault-keys.json) and is idempotent (verified in Session 7-2b: a plain re-run exits 0
# and leaves the database connection untouched).
#
# Run by the LaunchAgent com.edge-demo.mac-resume (installed with `make install-mac-resume`) at
# user login.  It does NOT change login or FileVault settings: you log in, this does the rest.
# Can also be run by hand:  bash scripts/mac-resume.sh
#
# Runs ON THE MAC only.  Log: ~/edge-device-demo/.mac-resume.log
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

LOG="${PWD}/.mac-resume.log"
exec >>"${LOG}" 2>&1
echo "=== mac-resume $(date '+%Y-%m-%d %H:%M:%S') ==="

# 1. Wait for the Docker daemon (Docker Desktop starts at login, takes a while).
for i in $(seq 1 60); do
  /usr/local/bin/docker info >/dev/null 2>&1 && break
  [ "$i" -eq 60 ] && { echo "FAIL: Docker daemon not ready after 5 min"; exit 1; }
  sleep 5
done
echo "docker ready"

# 2. Containers up (no-op if already running), then unseal + provision (idempotent).
make up-mac || { echo "FAIL: make up-mac"; exit 1; }

# 3. Wait until Vault answers over TLS (sealed is fine: sealedcode=200).  A freshly created container
#    needed more than the 75 s of the first version's retries (measured 2026-11-03).
for i in $(seq 1 60); do
  curl -s --max-time 5 --cacert tls/vault.crt -o /dev/null -f \
    "https://127.0.0.1:8200/v1/sys/health?uninitcode=200&sealedcode=200" && break
  [ "$i" -eq 60 ] && { echo "FAIL: Vault not answering after 5 min"; exit 1; }
  sleep 5
done
echo "vault answering"

# .env's VAULT_ADDR is the LAN IP, which this job could not reach (timeout); use loopback (in the cert SANs).
export VAULT_ADDR_OVERRIDE="https://127.0.0.1:8200"
for i in 1 2 3 4 5; do
  if make setup-vault; then
    echo "OK: vault unsealed and provisioned"
    exit 0
  fi
  echo "setup-vault failed (attempt ${i}/5), retrying in 15 s"
  sleep 15
done
echo "FAIL: make setup-vault did not succeed after 5 attempts"
exit 1
