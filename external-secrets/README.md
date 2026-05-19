# External Secrets Operator

Deploys External Secrets Operator using two Argo CD Applications: one for CRDs (sync-wave `-5`) and one for the controller (sync-wave `0`). Manages the `ClusterSecretStore vault-backend` used by all other apps.

## Structure

```
external-secrets-crds.yml              # ArgoCD Application — CRDs only (sync-wave -5, Prune=false)
external-secrets-controller.yml        # ArgoCD Application — operator controller (sync-wave 0)
values.yml                             # Helm values for the controller (installCRDs: false)
postgresql.clusterexternalsecret.yml   # ClusterExternalSecret — materializes postgresql-helm Secret
```

## Vault Bootstrap

Enable Kubernetes auth and configure the ESO role (run once after Vault is initialized):

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

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

# Enable KV v2
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault secrets enable -path=secret kv-v2 || true
"

# Create initial ESO role (add policies as you deploy each app)
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault write auth/kubernetes/role/external-secrets \
    bound_service_account_names='external-secrets' \
    bound_service_account_namespaces='external-secrets' \
    policies='default' ttl='1h'
"
```

## Deploy

Apply CRDs first, then the controller:

```bash
kubectl apply -f external-secrets/external-secrets-crds.yml
# Wait ~30s for CRDs to register
kubectl apply -f external-secrets/external-secrets-controller.yml
```

## Verification

```bash
# Operator pods
kubectl -n external-secrets get pods

# CRDs installed
kubectl get crds | grep external-secrets

# ClusterSecretStore ready
kubectl get clustersecretstore vault-backend

# ClusterExternalSecret for PostgreSQL
kubectl describe clusterexternalsecret postgresql-helm
kubectl -n postgresql describe externalsecret postgresql-helm
kubectl -n postgresql get secret postgresql-helm -o yaml
```

## Notes

- CRD app: `ServerSideApply=true`, `Prune=false` to avoid accidental CRD deletions.
- Controller runs with `replicaCount: 1`; adjust in `values.yml` if needed.
- Sync order enforced via annotations: CRDs wave `-5`, controller wave `0`.
- **Adding a policy to the ESO role**: always retrieve current policies first — writing replaces the entire list.

## Troubleshooting

- **CRDs missing**: ensure the CRD application is synced with `installCRDs: true`.
- **Store NotReady**: ensure the controller deployment `external-secrets` exists and SA `external-secrets` exists in namespace `external-secrets`.
- **Provider failures**: inspect controller logs: `kubectl -n external-secrets logs deploy/external-secrets`.
- **Invalid provider config**: verify `server` URL (e.g. `http://vault.vault.svc:8200`) and the Kubernetes auth role is bound to the SA.
