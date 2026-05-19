# Trivy UI

Deploys [locustbaby/trivy-ui](https://github.com/locustbaby/trivy-ui) via Helm, managed by Argo CD. Provides a web dashboard for Trivy Operator vulnerability reports, with kubeconfig-based multi-cluster access.

## Structure

```
application.yml                    # ArgoCD Application — chart trivy-ui
values.yml                         # Helm values (ingress, cache PVC, kubeconfigs ref)
kustomization.yml                  # Includes namespace + kubeconfigs.externalsecret.yml
namespace.yml                      # trivy-ui namespace
kubeconfigs.externalsecret.yml     # ESO — creates Secret kubeconfigs from Vault
```

## Vault Setup

Seed kubeconfig(s) before first sync. Each cluster is stored as a separate property under `secret/trivy-ui/kubeconfigs`.

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

# Seed the local cluster kubeconfig (base64-encoded)
KUBECONFIG_B64="$(kubectl config view --raw --minify | base64 -w0)"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/trivy-ui/kubeconfigs \
    local='$KUBECONFIG_B64'
"
```

> Add additional clusters as extra properties (`cluster2='...'`, etc.) and update `kubeconfigs.externalsecret.yml` with matching `data` entries.

### Vault Policy

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault policy write trivy-ui - <<EOF
path \"secret/data/trivy-ui/*\" {
  capabilities = [\"read\"]
}
EOF
"
```

### Extend ESO Role

```bash
CURRENT=$(kubectl exec -n vault vault-0 -c vault -- sh -c \
  'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault read -field=policies auth/kubernetes/role/external-secrets' \
  | tr -d '[]' | tr ' ' ',')

kubectl exec -n vault vault-0 -c vault -- sh -c \
  'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault write auth/kubernetes/role/external-secrets \
    bound_service_account_names="external-secrets" \
    bound_service_account_namespaces="external-secrets" \
    policies="'"$CURRENT"',trivy-ui" ttl="1h"'
```

## Deploy

Commit and push — Argo CD will sync the app to namespace `trivy-ui`.

## Verification

```bash
# Pods
kubectl -n trivy-ui get pods

# ExternalSecret synced
kubectl -n trivy-ui describe externalsecret trivy-ui-kubeconfigs

# Force reconcile
kubectl -n trivy-ui annotate externalsecret trivy-ui-kubeconfigs \
  reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite

# Confirm kubeconfigs secret created
kubectl -n trivy-ui get secret kubeconfigs -o jsonpath='{.data}' | jq 'keys'

# PVC bound
kubectl -n trivy-ui get pvc

# TLS certificate issued
kubectl -n trivy-ui get certificate
```

## Notes

- URL: `https://trivy-ui.apps.k8s.enros.me`
- Cache storage: `kadalu.kadalu-pool-replica3`, 2Gi PVC mounted at `/cache`
- Kubeconfigs mounted from Secret `kubeconfigs` at `/kubeconfigs` (one file per cluster)
- TLS managed by cert-manager via `letsencrypt-production` — no Vault secret needed for certs

## Troubleshooting

- **Secret not syncing**: ensure Vault policy covers `secret/data/trivy-ui/*` and ESO role includes `trivy-ui`.
- **Pod pending**: verify PVC bound (`kubectl -n trivy-ui get pvc`) and storage class available.
- **No cluster data**: confirm kubeconfig in secret has correct server URL and credentials; check `/kubeconfigs` dir inside pod.
- **404/ingress issues**: confirm Traefik is running and certificate is issued.
