# vault/policies/gateway-credstore-policy.hcl
# ACL policy for the OpenShell GATEWAY credential driver ("vault" driver, auth_method = token_file).
#
# The gateway stores provider credentials as KV-v2 secrets under
#   <mount>/openshell/provider-credentials/<40-hex-sha256-prefix>      (key "value")
# and keeps only an opaque handle ("v1:openshell/provider-credentials/<hash>") in its own database.
# Source: crates/openshell-driver-vault/src/lib.rs (managed_secret_path / api_path_for_reference /
# delete_api_path_for_reference), OpenShell v0.1.4 docs "Gateway Configuration File > Credential Drivers".
#
# Deliberately narrow: ONE prefix on ONE dedicated mount. No access to the Transit key, the database
# role, the camera KV mount or any auth/ path.
#
#   store   -> POST   <mount>/data/<path>        (create, update)
#   resolve -> GET    <mount>/data/<path>        (read)
#   delete  -> DELETE <mount>/metadata/<path>    (delete)
#   (list on the metadata prefix is used only by the 3-5d probe to find the entry it created)

path "edge-ai-demo-gateway/data/openshell/provider-credentials/*" {
  capabilities = ["create", "read", "update"]
}

path "edge-ai-demo-gateway/metadata/openshell/provider-credentials/*" {
  capabilities = ["read", "list", "delete"]
}
