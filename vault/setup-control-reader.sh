#!/usr/bin/env bash
# vault/setup-control-reader.sh   (runs on the Mac control plane, in ~/edge-device-demo)
#
# Session 5-3b — Payload Privacy Toggle: AppRole role `control-plane-reader`.
#
#   policy   edge-ai-demo-policy-control-reader   ONLY  edge-ai-demo-encryption-transit/decrypt/edge-telemetry [update]
#   role     auth/approle/role/control-plane-reader  token_no_default_policy=true, 5 m / 15 m token
#   keys     role_id + secret_id stored in .vault-keys.json under "control_plane_reader"
#
# Also re-applies edge-ai-demo-policy-edge (Session 5-3b added: admin-key create+read, and
# sys/leases/revoke/<db-role>/* for "Rotate Secret Now") and proves, with THROW-AWAY tokens:
#   control-plane-reader : decrypt of a real stored datakey OK; encrypt / datakey / KV / DB creds = denied
#   edge policy          : decrypt denied; revoke path = update; body-form revoke / other prefix = denied
#   gateway policy       : decrypt denied
#
# Idempotent. Uses the root token from .vault-keys.json (never leaves the Mac).  The plaintext DEK that the
# proof decrypts is never printed (only its length).
#
# Docs: AppRole  https://developer.hashicorp.com/vault/api-docs/auth/approle
#       Transit  https://developer.hashicorp.com/vault/api-docs/secret/transit#decrypt-data
#       Leases   https://developer.hashicorp.com/vault/api-docs/system/leases#revoke-lease
#
# Usage on the Mac:   make setup-control-reader
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

ROLE="control-plane-reader"
POLICY="edge-ai-demo-policy-control-reader"
POLICY_FILE="vault/policies/edge-ai-demo-policy-control-reader.hcl"
EDGE_POLICY="edge-ai-demo-policy-edge"
EDGE_POLICY_FILE="vault/policies/edge-agent-policy.hcl"
GW_POLICY="edge-ai-demo-policy-gateway"
TRANSIT="edge-ai-demo-encryption-transit"
KEY="edge-telemetry"
DB_ROLE_PATH="edge-ai-demo-database/creds/edge-camera-agent"

export VAULT_ADDR VAULT_CACERT

ok()   { echo "  ✓ $*"; }
info() { echo "  ▷ $*"; }
err()  { echo "  ✗ $*" >&2; exit 1; }
sep()  { echo; echo "── $* ──────────────────────────────────────────────────────────────────"; }

command -v vault >/dev/null || err "vault CLI not found (brew install vault)"
for f in "${KEYS_FILE}" "${POLICY_FILE}" "${EDGE_POLICY_FILE}"; do [[ -f "${f}" ]] || err "${f} not found"; done

VAULT_TOKEN="$(python3 -c "import json;print(json.load(open('${KEYS_FILE}'))['root_token'])")"
export VAULT_TOKEN
vault status >/dev/null 2>&1 || err "Vault not reachable/unsealed at ${VAULT_ADDR}"
ok "Vault reachable at ${VAULT_ADDR}"

REVOKE_TOKENS=()
cleanup() { for t in "${REVOKE_TOKENS[@]:-}"; do [[ -n "${t}" ]] && VAULT_TOKEN="${VAULT_TOKEN}" vault token revoke "${t}" >/dev/null 2>&1 || true; done; }
trap cleanup EXIT

# ── 1. policies ──────────────────────────────────────────────────────────────
sep "1. policies"
vault policy write "${POLICY}" "${POLICY_FILE}" >/dev/null
ok "policy ${POLICY} written from ${POLICY_FILE}"
vault policy write "${EDGE_POLICY}" "${EDGE_POLICY_FILE}" >/dev/null
ok "policy ${EDGE_POLICY} re-written from ${EDGE_POLICY_FILE} (admin-key + lease-revoke grants)"

# ── 2. AppRole role ──────────────────────────────────────────────────────────
sep "2. AppRole role ${ROLE}"
vault auth list -format=json | python3 -c "import json,sys;sys.exit(0 if 'approle/' in json.load(sys.stdin) else 1)" \
  || err "approle auth is not enabled (run make setup-vault first)"
vault write "auth/approle/role/${ROLE}" \
  token_policies="${POLICY}" \
  token_no_default_policy=true \
  token_ttl=5m token_max_ttl=15m token_num_uses=0 \
  secret_id_ttl=0 bind_secret_id=true >/dev/null
GOT="$(vault read -format=json "auth/approle/role/${ROLE}" | python3 -c "
import json,sys
d=json.load(sys.stdin)['data']
print(','.join(sorted(d['token_policies'])), d['token_no_default_policy'], d['token_ttl'], d['token_max_ttl'])")"
[[ "${GOT}" == "${POLICY} True 300 900" ]] || err "unexpected role config: ${GOT}"
ok "role ${ROLE}: policies=${POLICY} token_no_default_policy=true token_ttl=300 token_max_ttl=900"

# ── 3. role_id / secret_id -> .vault-keys.json ───────────────────────────────
sep "3. role_id + secret_id -> ${KEYS_FILE} [control_plane_reader]"
ROLE_ID="$(vault read -field=role_id "auth/approle/role/${ROLE}/role-id")"
REUSE=false
if python3 - "${KEYS_FILE}" "${ROLE_ID}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])).get("control_plane_reader") or {}
sys.exit(0 if d.get("role_id") == sys.argv[2] and d.get("secret_id") else 1)
PY
then
  SECRET_ID="$(python3 -c "import json;print(json.load(open('${KEYS_FILE}'))['control_plane_reader']['secret_id'])")"
  if vault write -field=token auth/approle/login role_id="${ROLE_ID}" secret_id="${SECRET_ID}" >/dev/null 2>&1; then
    REUSE=true; ok "existing secret_id in ${KEYS_FILE} still logs in — reused"
  fi
fi
if ! ${REUSE}; then
  SECRET_ID="$(vault write -f -field=secret_id "auth/approle/role/${ROLE}/secret-id")"
  python3 - "${KEYS_FILE}" "${ROLE_ID}" "${SECRET_ID}" <<'PY'
import json, os, sys
f, rid, sid = sys.argv[1:4]
d = json.load(open(f))
d["control_plane_reader"] = {"role_id": rid, "secret_id": sid}
tmp = f + ".tmp"
with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as fh:
    json.dump(d, fh, indent=2)
os.replace(tmp, f)
os.chmod(f, 0o600)
PY
  ok "new secret_id generated and stored under control_plane_reader (file chmod 600)"
fi
unset SECRET_ID

# ── 4. proofs ────────────────────────────────────────────────────────────────
sep "4. Narrowness proofs (throw-away tokens; values are never printed)"
CT="$(/usr/local/bin/docker exec -i postgres psql -U "${POSTGRES_USER:?set POSTGRES_USER in .env}" -d "${POSTGRES_DB:?set POSTGRES_DB in .env}" -tAc \
      "select encrypted_datakey from events where encrypted_datakey like 'vault:v1:%' order by id desc limit 1" | tr -d '[:space:]')" \
  || err "could not query the events table on the Mac (is the postgres container up?)"
if [[ "${CT}" != vault:v1:* ]]; then
  # Session 7-2e: on a fresh install the events table is empty until the Jetson pipeline has written a row.
  # The role + secret_id (sections 1-3) are done; the proofs need a real stored datakey and are NOT RUN.
  # Re-run `make setup-control-reader` after the Jetson phase to run them. Exit 0 is for sections 1-3 only.
  echo
  echo "  ⚠ NOT RUN: narrowness proofs (section 4) - no stored encrypted_datakey in events yet (fresh install?)."
  echo "    Sections 1-3 (policies, role, role_id/secret_id in ${KEYS_FILE}) completed."
  echo "    Re-run 'make setup-control-reader' once the Jetson pipeline has written events to run the proofs."
  exit 0
fi
info "real stored datakey ciphertext used for the proofs (${#CT} chars; not printed)"

http_code() {   # $1=token  $2=path  $3...=json body ; prints HTTP status
  local body="${3:-}"; [[ -n "${body}" ]] || body='{}'
  curl -s -o /dev/null -w '%{http_code}' --cacert "${VAULT_CACERT}" -X "${4:-POST}" \
       -H "X-Vault-Token: $1" -d "${body}" "${VAULT_ADDR}/v1/$2"
}
expect() {      # desc expected actual
  if [[ "$3" == "$2" ]]; then ok "$1 -> HTTP $3"; else err "$1 -> HTTP $3, expected $2"; fi
}

RDR_TOK="$(vault write -field=token auth/approle/login role_id="$(python3 -c "import json;print(json.load(open('${KEYS_FILE}'))['control_plane_reader']['role_id'])")" secret_id="$(python3 -c "import json;print(json.load(open('${KEYS_FILE}'))['control_plane_reader']['secret_id'])")")"
REVOKE_TOKENS+=("${RDR_TOK}")
POL_SEEN="$(vault token lookup -format=json "${RDR_TOK}" | python3 -c "import json,sys;print(','.join(json.load(sys.stdin)['data']['policies']))")"
[[ "${POL_SEEN}" == "${POLICY}" ]] || err "reader token policies are '${POL_SEEN}', expected only ${POLICY}"
ok "AppRole login works; token policies = ${POL_SEEN} (no default policy)"

echo "  — control-plane-reader —"
DEC_BODY="$(curl -s --cacert "${VAULT_CACERT}" -H "X-Vault-Token: ${RDR_TOK}" -d "{\"ciphertext\":\"${CT}\"}" "${VAULT_ADDR}/v1/${TRANSIT}/decrypt/${KEY}")"
DEK_LEN="$(python3 -c "import base64,json,sys;print(len(base64.b64decode(json.loads(sys.argv[1])['data']['plaintext'])))" "${DEC_BODY}")"
[[ "${DEK_LEN}" == "32" ]] || err "reader decrypt did not return a 32-byte DEK (got ${DEK_LEN})"
ok "allowed : decrypt real stored datakey -> 32-byte DEK (not printed)"
expect "denied  : transit/encrypt/${KEY} (plaintext=dGVzdA==)" 403 "$(http_code "${RDR_TOK}" "${TRANSIT}/encrypt/${KEY}" '{"plaintext":"dGVzdA=="}')"
expect "denied  : transit/datakey/plaintext/${KEY}"            403 "$(http_code "${RDR_TOK}" "${TRANSIT}/datakey/plaintext/${KEY}")"
expect "denied  : transit/rewrap/${KEY}"                       403 "$(http_code "${RDR_TOK}" "${TRANSIT}/rewrap/${KEY}" "{\"ciphertext\":\"${CT}\"}")"
expect "denied  : read edge-ai-demo-kv/data/edge-device/camera-creds" 403 "$(http_code "${RDR_TOK}" "edge-ai-demo-kv/data/edge-device/camera-creds" '' GET)"
expect "denied  : read ${DB_ROLE_PATH}"                        403 "$(http_code "${RDR_TOK}" "${DB_ROLE_PATH}" '' GET)"
expect "denied  : auth/token/lookup-self (no default policy)"  403 "$(http_code "${RDR_TOK}" "auth/token/lookup-self" '' GET)"

echo "  — edge policy (throw-away token, ONLY ${EDGE_POLICY}) —"
ED_TOK="$(vault token create -policy="${EDGE_POLICY}" -no-default-policy -ttl=5m -field=token)"; REVOKE_TOKENS+=("${ED_TOK}")
expect "denied  : decrypt ${TRANSIT}/decrypt/${KEY} (real ciphertext)" 403 "$(http_code "${ED_TOK}" "${TRANSIT}/decrypt/${KEY}" "{\"ciphertext\":\"${CT}\"}")"
ED_CAPS_REV="$(vault token capabilities "${ED_TOK}" "sys/leases/revoke/${DB_ROLE_PATH}/abc" | tr -d ' ')"
[[ "${ED_CAPS_REV}" == "update" ]] && ok "allowed : sys/leases/revoke/${DB_ROLE_PATH}/<id> capabilities = update" \
  || err "edge revoke-path capabilities are '${ED_CAPS_REV}', expected update"
for p in "sys/leases/revoke" "sys/leases/revoke-prefix/${DB_ROLE_PATH}" "sys/leases/revoke-force/${DB_ROLE_PATH}" \
         "sys/leases/revoke/edge-ai-demo-gateway/creds/x/abc" "sys/leases/lookup"; do
  C="$(vault token capabilities "${ED_TOK}" "${p}" | tr -d ' ')"
  [[ "${C}" == "deny" ]] && ok "denied  : capabilities on ${p} = deny" || err "edge capabilities on ${p} are '${C}', expected deny"
done
AK="$(vault token capabilities "${ED_TOK}" "edge-ai-demo-kv/data/edge-device/admin-key" | tr -d ' ')"
[[ "${AK}" == "create,read" || "${AK}" == "read,create" ]] && ok "allowed : edge-ai-demo-kv/data/edge-device/admin-key capabilities = create,read" \
  || err "edge admin-key capabilities are '${AK}', expected create,read"

echo "  — gateway policy (throw-away token, ONLY ${GW_POLICY}) —"
GW_TOK="$(vault token create -policy="${GW_POLICY}" -no-default-policy -ttl=5m -field=token)"; REVOKE_TOKENS+=("${GW_TOK}")
expect "denied  : decrypt ${TRANSIT}/decrypt/${KEY} (real ciphertext)" 403 "$(http_code "${GW_TOK}" "${TRANSIT}/decrypt/${KEY}" "{\"ciphertext\":\"${CT}\"}")"

echo
echo "==> control-plane-reader ready."
echo "    role_id/secret_id are in ${KEYS_FILE} [control_plane_reader] (chmod 600, gitignored)."
echo "    Next: ./scripts/bootstrap-jetson.sh ${JETSON_IP:-<jetson-ip>} --only-stage 5-3b"
