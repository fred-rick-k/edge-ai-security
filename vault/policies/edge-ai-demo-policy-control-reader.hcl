# vault/policies/edge-ai-demo-policy-control-reader.hcl
# ACL policy for the AppRole role `control-plane-reader` (Session 5-3b, Payload Privacy Toggle).
#
# ONE capability: Transit decrypt with the key edge-telemetry. Nothing else.
#   - NOT granted: transit encrypt, datakey/*, rewrap          (it cannot create or re-wrap ciphertext)
#   - NOT granted: edge-ai-demo-kv/ (camera RTSP URL, ingest/admin key hashes)
#   - NOT granted: edge-ai-demo-database/ (dynamic DB credentials)
#   - NOT granted: edge-ai-demo-gateway/, sys/, auth/
# The role is created with token_no_default_policy=true, so the token cannot even lookup-self.
# Narrowness is proven with throw-away tokens by vault/setup-control-reader.sh.

path "edge-ai-demo-encryption-transit/decrypt/edge-telemetry" {
  capabilities = ["update"]
}
