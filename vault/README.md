# HashiCorp Vault (Argo CD App)

## Overview
- Deploys HashiCorp Vault via the official Helm chart managed by Argo CD.
- Includes additional manifests (RBAC, init job) to bootstrap Vault and integrate with cluster workloads.

## Files
- `vault/application.yml`: Argo CD Application referencing the HashiCorp Helm chart and local values.
- `vault/values.yml`: Helm values for Vault server configuration (storage, service type, HA, etc.).
- `vault/kustomization.yml`: Kustomize overlay for local resources.
- `vault/namespace.yml`: Namespace definition for `vault`.
- `vault/rbac.yml`: Service accounts/roles for Vault integration.
- `vault/init-job.yml`: Init job for bootstrapping tasks (e.g., unseal/setup/policies).

## Configuration Highlights
- Configure storage backend (e.g., Raft) and service exposure in `values.yml`.
- Adjust HA and resources to suit cluster capacity.
- Integrate with External Secrets by creating `SecretStore` pointing to Vault.

## Deploy
- Commit and push; Argo CD will sync to the `vault` namespace and apply overlay resources.

### Manual Bootstrap (Bash)
- If the init job initialized Vault, you'll find a bootstrap secret `vault-root-token`:
  - `TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d 2>/dev/null || echo)"`
- If it’s empty, use an admin-capable token obtained via Vault UI/CLI (e.g., login with root/admin and set `TOKEN` accordingly):
  - `export TOKEN=<your-admin-token>`
- Enable KV v2 secrets engine at `secret/`:
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault secrets enable -path=secret kv-v2'`
- Create Harbor admin read policy:
  - `cat > harbor-admin.hcl <<'EOF'
path "secret/data/harbor/admin" {
  capabilities = ["read"]
}
EOF`
  - `kubectl cp harbor-admin.hcl vault/vault-0:/tmp/harbor-admin.hcl -c vault`
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault policy write harbor-admin /tmp/harbor-admin.hcl'`
- Enable Kubernetes auth and bind role for External Secrets:
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault auth enable kubernetes || true'`
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc" kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt'`
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault write auth/kubernetes/role/external-secrets bound_service_account_names="external-secrets" bound_service_account_namespaces="external-secrets" policies="harbor-admin" ttl="1h"'`
- Seed Harbor admin password:
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault kv put secret/harbor/admin admin_password="YOUR_STRONG_PASSWORD"'`

## Manual Verification
- `kubectl -n vault get pods`
- `kubectl -n vault logs statefulset/vault` (or deployment depending on chosen mode)
- Verify service and readiness: `kubectl -n vault get svc`
- `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault secrets list | grep "^secret/"'`
- `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault policy read harbor-admin'`

## Troubleshooting
- Init job failures: inspect `vault/init-job.yml` logs and ensure RBAC allows needed actions.
- Unseal/setup flow: confirm values and bootstrap logic match desired operational model.
- Storage issues: check PVCs/PV and Raft health.

## Updating
- Bump chart `targetRevision` in `vault/application.yml`.
- Tune `vault/values.yml` for performance, auth methods, and policies.
