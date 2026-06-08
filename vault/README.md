# HashiCorp Vault

Deploys HashiCorp Vault via the official Helm chart, managed by Argo CD. Includes RBAC and an init job for bootstrapping. Acts as the secret store for all other apps via External Secrets Operator.

## Structure

```
application.yml   # ArgoCD Application — HashiCorp chart + values.yml
values.yml        # Helm values (storage backend, service type, HA, resources)
kustomization.yml # Kustomize overlay
namespace.yml     # vault namespace
rbac.yml          # Service accounts and roles for Vault integration
init-job.yml      # Bootstrap job (unseal, policies, initial setup)
```

## Bootstrap

After first sync, initialize Vault and configure Kubernetes auth:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d 2>/dev/null || echo)"
# If empty, obtain from Vault UI/CLI: export TOKEN=<your-admin-token>

# Enable KV v2
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault secrets enable -path=secret kv-v2 || true
"

# Enable Kubernetes auth
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault auth enable kubernetes || true
"

# Configure Kubernetes auth
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault write auth/kubernetes/config \
    kubernetes_host='https://kubernetes.default.svc' \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
"
```

### Create initial ESO policy and role

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault policy write harbor-admin - <<EOF
path \"secret/data/harbor/admin\" {
  capabilities = [\"read\"]
}
EOF
"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault write auth/kubernetes/role/external-secrets \
    bound_service_account_names='external-secrets' \
    bound_service_account_namespaces='external-secrets' \
    policies='harbor-admin' ttl='1h'
"
```

## Verification

```bash
# Vault pod and service
kubectl -n vault get pods
kubectl -n vault get svc

# Vault logs
kubectl -n vault logs statefulset/vault

# List secrets engines
kubectl exec -n vault vault-0 -c vault -- sh -c \
  'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault secrets list'

# Read a policy
kubectl exec -n vault vault-0 -c vault -- sh -c \
  'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault policy read harbor-admin'
```

## Notes

- Vault address (in-cluster): `http://vault.vault.svc:8200`
- ClusterSecretStore name: `vault-backend` (configured in external-secrets app)
- The init job stores the root token and unseal key as a Kubernetes Secret `vault-root-token` in the `vault` namespace, with keys `token` and `unseal_key`.
- **Adding a policy to the ESO role** always replaces the full policy list — retrieve current policies first (see CLAUDE.md).

## Troubleshooting

- **Init job failures**: inspect logs: `kubectl -n vault logs job/vault-init`.
- **Vault sealed**: unseal with the key stored in the `vault-root-token` Secret:
  ```bash
  UNSEAL_KEY="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.unseal_key}' | base64 -d)"
  kubectl exec -n vault vault-0 -c vault -- sh -c \
    "VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal '${UNSEAL_KEY}'"
  ```
- **Storage issues**: check PVC binding and Raft health.
- **ESO cannot authenticate**: confirm Kubernetes auth is enabled and the role `external-secrets` is bound to SA `external-secrets` in namespace `external-secrets`.
