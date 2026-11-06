#!/usr/bin/env bash
# vault/setup-gateway-credstore.sh   (runs on the Mac control plane, in ~/edge-device-demo)
#
# Session 3-5e — split into two least-privilege TPM identities:
#
#   auth/tpm/role/edge-camera-agent   token_policies = [edge-ai-demo-policy-edge]   (trusted-edge service)
#   auth/tpm/role/openshell-gateway   token_policies = [edge-ai-demo-policy-gateway] (OpenShell gateway driver)
#
# Both roles bind the same tpmgroup (orin-nano-devices) so both are obtained via the
# same hardware TPM attestation flow (auth/tpm login).  The separation is enforced by
# writing two different token files on the Jetson (Session 3-5f).
#
# Steps:
#   1. KV-v2 mount  edge-ai-demo-gateway/            (create if absent; idempotent)
#   2. policy       edge-ai-demo-policy-gateway      (vault/policies/gateway-credstore-policy.hcl)
#   3. policy       edge-ai-demo-policy-edge         (vault/policies/edge-agent-policy.hcl)
#      — re-written here to ensure transit encrypt/decrypt are absent
#   4. TPM role  openshell-gateway: token_policies = [edge-ai-demo-policy-gateway], same tpmgroup_ids, 1h/4h
#   5. TPM role  edge-camera-agent: token_policies = [edge-ai-demo-policy-edge] ONLY (remove gateway policy)
#   6. narrowness proof — gateway policy (allowed/denied)
#   7. narrowness proof — edge policy (allowed/denied)
#
# Idempotent. Uses the root token from .vault-keys.json (never leaves the Mac).
#
# Usage on the Mac:
#   make setup-gateway-credstore
#   — or —
#   PATH=/opt/homebrew/bin:$PATH VAULT_CACERT=tls/vault.crt bash vault/setup-gateway-credstore.sh

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ -f ".env" ]]; then
  set -a
  # shellcheck disable=SC1090,SC1091
  source ".env"
  set +a
fi

VAULT_ADDR="${VAULT_ADDR:-https://127.0.0.1:8200}"
VAULT_CACERT="${VAULT_CACERT:-tls/vault.crt}"
KEYS_FILE="${KEYS_FILE:-.vault-keys.json}"

MOUNT="edge-ai-demo-gateway"
GW_POLICY="edge-ai-demo-policy-gateway"
GW_POLICY_FILE="vault/policies/gateway-credstore-policy.hcl"
EDGE_POLICY="edge-ai-demo-policy-edge"
EDGE_POLICY_FILE="vault/policies/edge-agent-policy.hcl"

EDGE_ROLE="edge-camera-agent"
GW_ROLE="openshell-gateway"

export VAULT_ADDR VAULT_CACERT

ok()   { echo "  ✓ $*"; }
info() { echo "  ▷ $*"; }
err()  { echo "  ✗ $*" >&2; exit 1; }
sep()  { echo; echo "── $* ──────────────────────────────────────────────────────────────────"; }

command -v vault >/dev/null || err "vault CLI not found (brew install vault)"
[[ -f "${KEYS_FILE}" ]]        || err "${KEYS_FILE} not found"
[[ -f "${GW_POLICY_FILE}" ]]   || err "${GW_POLICY_FILE} not found"
[[ -f "${EDGE_POLICY_FILE}" ]] || err "${EDGE_POLICY_FILE} not found"

VAULT_TOKEN="$(python3 -c "import json;print(json.load(open('${KEYS_FILE}'))['root_token'])")"
export VAULT_TOKEN
vault status >/dev/null 2>&1 || err "Vault not reachable/unsealed at ${VAULT_ADDR}"
ok "Vault reachable at ${VAULT_ADDR}"

# ── 1. KV-v2 mount ───────────────────────────────────────────────────────────
sep "1. mount ${MOUNT}/"
if vault secrets list -format=json | python3 -c "import json,sys;sys.exit(0 if '${MOUNT}/' in json.load(sys.stdin) else 1)"; then
  ok "mount ${MOUNT}/ already enabled"
else
  vault secrets enable -path="${MOUNT}" -version=2 kv >/dev/null
  ok "enabled KV-v2 mount ${MOUNT}/"
fi

# ── 2. gateway policy ────────────────────────────────────────────────────────
sep "2. policy ${GW_POLICY}"
vault policy write "${GW_POLICY}" "${GW_POLICY_FILE}" >/dev/null
ok "policy ${GW_POLICY} written from ${GW_POLICY_FILE}"

# ── 3. edge policy (re-apply to ensure transit encrypt/decrypt are gone) ─────
sep "3. policy ${EDGE_POLICY}"
vault policy write "${EDGE_POLICY}" "${EDGE_POLICY_FILE}" >/dev/null
ok "policy ${EDGE_POLICY} written from ${EDGE_POLICY_FILE}"

# ── 4. TPM role openshell-gateway ────────────────────────────────────────────
sep "4. TPM role ${GW_ROLE}"

# Read tpmgroup_ids from the existing edge-camera-agent role (it was set by setup-tpm-auth.sh).
EDGE_ROLE_JSON="$(vault read -format=json "auth/tpm/role/${EDGE_ROLE}" 2>/dev/null)" \
  || err "auth/tpm/role/${EDGE_ROLE} not found — run make setup-tpm-auth first"
GROUP_IDS="$(python3 -c "import json,sys;print(','.join(json.load(sys.stdin)['data']['tpmgroup_ids']))" <<<"${EDGE_ROLE_JSON}")"
[[ -n "${GROUP_IDS}" ]] || err "auth/tpm/role/${EDGE_ROLE} has no tpmgroup_ids — refusing to create the gateway role"

# Create or update the openshell-gateway role with gateway policy ONLY.
vault write "auth/tpm/role/${GW_ROLE}" \
  tpm_ids= \
  tpmgroup_ids="${GROUP_IDS}" \
  token_policies="${GW_POLICY}" \
  token_ttl="1h" \
  token_max_ttl="4h" >/dev/null

GW_GOT="$(vault read -format=json "auth/tpm/role/${GW_ROLE}" | \
  python3 -c "import json,sys;print(','.join(sorted(json.load(sys.stdin)['data']['token_policies'])))")"
echo "${GW_GOT}" | grep -q "${GW_POLICY}"    || err "gateway role missing ${GW_POLICY}"
echo "${GW_GOT}" | grep -vq "edge-ai-demo-policy-edge" \
  || err "gateway role must NOT carry edge-ai-demo-policy-edge — got: ${GW_GOT}"
ok "auth/tpm/role/${GW_ROLE} token_policies = ${GW_GOT}  (tpmgroup_ids=${GROUP_IDS}, ttl=1h, max=4h)"

# ── 5. TPM role edge-camera-agent: edge policy ONLY ──────────────────────────
sep "5. TPM role ${EDGE_ROLE} — enforce edge policy only"

TTL="$(python3 -c "import json,sys;print(json.load(sys.stdin)['data']['token_ttl'])" <<<"${EDGE_ROLE_JSON}")"
MAXTTL="$(python3 -c "import json,sys;print(json.load(sys.stdin)['data']['token_max_ttl'])" <<<"${EDGE_ROLE_JSON}")"

vault write "auth/tpm/role/${EDGE_ROLE}" \
  tpm_ids= \
  tpmgroup_ids="${GROUP_IDS}" \
  token_policies="${EDGE_POLICY}" \
  token_ttl="${TTL}" \
  token_max_ttl="${MAXTTL}" >/dev/null

EDGE_GOT="$(vault read -format=json "auth/tpm/role/${EDGE_ROLE}" | \
  python3 -c "import json,sys;print(','.join(sorted(json.load(sys.stdin)['data']['token_policies'])))")"
echo "${EDGE_GOT}" | grep -q "${EDGE_POLICY}"   || err "edge role missing ${EDGE_POLICY}"
echo "${EDGE_GOT}" | grep -vq "${GW_POLICY}" \
  || err "edge role must NOT carry ${GW_POLICY} — got: ${EDGE_GOT}"
ok "auth/tpm/role/${EDGE_ROLE} token_policies = ${EDGE_GOT}  (tpmgroup_ids=${GROUP_IDS}, ttl=${TTL}, max=${MAXTTL})"

# ── 6. Narrowness proof — gateway policy ─────────────────────────────────────
sep "6. Narrowness proof: ${GW_POLICY}"
info "creating throw-away token carrying ONLY ${GW_POLICY}"
GW_TOK="$(vault token create -policy="${GW_POLICY}" -no-default-policy -ttl=2m -field=token)"
GW_PROBE="openshell/provider-credentials/narrowness-check"

gw() { VAULT_TOKEN="${GW_TOK}" "$@"; }

deny_gw() {
  local d="$1"; shift
  if gw "$@" >/dev/null 2>&1; then
    vault token revoke "${GW_TOK}" >/dev/null 2>&1 || true
    err "GATEWAY NOT denied: ${d}"
  else
    ok "denied  : ${d}"
  fi
}

gw vault kv put   -mount="${MOUNT}" "${GW_PROBE}" value=probe >/dev/null && ok "allowed : write  ${MOUNT}/${GW_PROBE}"
[[ "$(gw vault kv get -mount="${MOUNT}" -field=value "${GW_PROBE}")" == "probe" ]] \
  && ok "allowed : read   ${MOUNT}/${GW_PROBE}"
gw vault kv list  -mount="${MOUNT}" openshell/provider-credentials >/dev/null \
  && ok "allowed : list   ${MOUNT}/openshell/provider-credentials"
gw vault kv metadata delete -mount="${MOUNT}" "${GW_PROBE}" >/dev/null \
  && ok "allowed : delete ${MOUNT}/metadata/${GW_PROBE}"

deny_gw "read   edge-ai-demo-kv/edge-device/camera-creds"           vault kv get -mount=edge-ai-demo-kv edge-device/camera-creds
deny_gw "update transit datakey edge-telemetry"                     vault write -f edge-ai-demo-encryption-transit/datakey/plaintext/edge-telemetry
deny_gw "read   edge-ai-demo-database/creds/edge-camera-agent"      vault read edge-ai-demo-database/creds/edge-camera-agent
deny_gw "write  ${MOUNT}/data/other/outside-prefix"                 vault kv put -mount="${MOUNT}" other/outside-prefix value=x
deny_gw "read   sys/policy/default"                                 vault read sys/policy/default
deny_gw "update transit/encrypt/edge-telemetry"                     vault write -f edge-ai-demo-encryption-transit/encrypt/edge-telemetry plaintext=dGVzdA==

vault token revoke "${GW_TOK}" >/dev/null 2>&1 || true
ok "gateway throw-away token revoked"

# ── 7. Narrowness proof — edge policy ────────────────────────────────────────
sep "7. Narrowness proof: ${EDGE_POLICY}"
info "creating throw-away token carrying ONLY ${EDGE_POLICY}"
EDGE_TOK="$(vault token create -policy="${EDGE_POLICY}" -no-default-policy -ttl=2m -field=token)"

ed() { VAULT_TOKEN="${EDGE_TOK}" "$@"; }

deny_ed() {
  local d="$1"; shift
  if ed "$@" >/dev/null 2>&1; then
    vault token revoke "${EDGE_TOK}" >/dev/null 2>&1 || true
    err "EDGE NOT denied: ${d}"
  else
    ok "denied  : ${d}"
  fi
}

# Allowed paths
ed vault kv get    -mount=edge-ai-demo-kv edge-device/camera-creds >/dev/null \
  && ok "allowed : read   edge-ai-demo-kv/edge-device/camera-creds"
ed vault write -f  edge-ai-demo-encryption-transit/datakey/plaintext/edge-telemetry >/dev/null \
  && ok "allowed : update transit datakey edge-telemetry"
ed vault read      edge-ai-demo-database/creds/edge-camera-agent >/dev/null \
  && ok "allowed : read   edge-ai-demo-database/creds/edge-camera-agent"
ed vault read      auth/tpm/role/edge-camera-agent >/dev/null \
  && ok "allowed : read   auth/tpm/role/edge-camera-agent"
ed vault token lookup >/dev/null \
  && ok "allowed : token lookup-self"
ed vault token renew >/dev/null 2>&1; [[ $? -le 1 ]] \
  && ok "allowed : token renew-self (rc 0 or 1 — token too new is fine)"

# ingest-key: capabilities query only (a real write would burn the create-only slot
# that stage 3-5g needs). Exact set must be "create, read" — no update/delete.
# (root-side query: the throw-away token has no default policy, so capabilities-self is not granted)
ING_CAPS="$(vault token capabilities "${EDGE_TOK}" "edge-ai-demo-kv/data/edge-device/ingest-key" 2>/dev/null | tr -d ' ')"
if [[ "${ING_CAPS}" == "create,read" || "${ING_CAPS}" == "read,create" ]]; then
  ok "allowed : edge-ai-demo-kv/data/edge-device/ingest-key capabilities = create,read"
else
  vault token revoke "${EDGE_TOK}" >/dev/null 2>&1 || true
  err "EDGE ingest-key capabilities are '${ING_CAPS}', expected create,read"
fi

# Denied paths
deny_ed "write  ${MOUNT}/data/openshell/provider-credentials/x"     vault kv put -mount="${MOUNT}" openshell/provider-credentials/x value=x
deny_ed "delete edge-ai-demo-kv/metadata/edge-device/ingest-key"      vault kv metadata delete -mount=edge-ai-demo-kv edge-device/ingest-key
deny_ed "update transit/encrypt/edge-telemetry"                     vault write -f edge-ai-demo-encryption-transit/encrypt/edge-telemetry plaintext=dGVzdA==
deny_ed "update transit/decrypt/edge-telemetry"                     vault write edge-ai-demo-encryption-transit/decrypt/edge-telemetry ciphertext=vault:v1:AAAA
deny_ed "read   sys/policy/default"                                 vault read sys/policy/default

vault token revoke "${EDGE_TOK}" >/dev/null 2>&1 || true
ok "edge throw-away token revoked"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "==> Split complete."
echo "    auth/tpm/role/${EDGE_ROLE}  token_policies = ${EDGE_GOT}"
echo "    auth/tpm/role/${GW_ROLE}  token_policies = ${GW_GOT}"
echo "    Mount ${MOUNT}/ ready.  Policy ${GW_POLICY} written.  Policy ${EDGE_POLICY} written (transit encrypt/decrypt removed)."
echo
echo "    Next (Session 3-5f): split vault-agent into two token files on the Jetson."
echo "    Run: ./scripts/bootstrap-jetson.sh ${JETSON_IP:-<jetson-ip>} --only-stage 3-5f"
