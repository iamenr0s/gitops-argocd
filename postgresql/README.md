# PostgreSQL

Deploys PostgreSQL via the Bitnami Helm chart, managed by Argo CD. Persistent storage on Kadalu; credentials sourced from Vault via ClusterExternalSecret.

## Structure

```
application.yml                                     # ArgoCD Application — chart + values.yml
values.yml                                          # Helm values (persistence, metrics, existingSecret)
kustomization.yml                                   # Includes namespace.yml
namespace.yml                                       # postgresql namespace
external-secrets/postgresql.clusterexternalsecret.yml  # CES — creates ExternalSecret in postgresql namespace
```

## Vault Setup

Seed credentials before first sync:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/postgresql/helm \
    postgres_admin_password='<admin-password>' \
    postgres_user_password='<user-password>'
"
```

### Vault Policy

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault policy write postgresql - <<EOF
path \"secret/data/postgresql/*\" {
  capabilities = [\"read\"]
}
EOF
"
```

### Extend ESO role

```bash
CURRENT=$(kubectl exec -n vault vault-0 -c vault -- sh -c \
  'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault read -field=policies auth/kubernetes/role/external-secrets' \
  | tr -d '[]' | tr ' ' ',')

kubectl exec -n vault vault-0 -c vault -- sh -c \
  'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault write auth/kubernetes/role/external-secrets \
    bound_service_account_names="external-secrets" \
    bound_service_account_namespaces="external-secrets" \
    policies="'"$CURRENT"',postgresql" ttl="1h"'
```

## Deploy

Commit and push — Argo CD will sync to namespace `postgresql`.

## Verification

```bash
# Pods and services
kubectl -n postgresql get pods
kubectl -n postgresql get svc

# ClusterExternalSecret status
kubectl describe clusterexternalsecret postgresql-helm

# ExternalSecret in namespace
kubectl -n postgresql describe externalsecret postgresql-helm

# Force reconcile
kubectl -n postgresql annotate externalsecret postgresql-helm \
  reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite

# Decode credentials
kubectl -n postgresql get secret postgresql-helm \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl -n postgresql get secret postgresql-helm \
  -o jsonpath='{.data.user-password}' | base64 -d; echo
```

## Notes

- Internal DNS: `postgresql-postgresql.postgresql.svc.cluster.local:5432`
- Default user: `app`, database: `appdb`
- Storage class: `kadalu.kadalu-pool-replica3` (20Gi)
- Metrics enabled; ServiceMonitor targets namespace `monitoring`.

## Troubleshooting

- **DB connection refused**: check pod status and PVC binding: `kubectl -n postgresql get pvc`.
- **CES not reconciling**: verify `external-secrets` controller is healthy: `kubectl get crds | grep external-secrets`.
- **Wrong password**: re-seed Vault and force ExternalSecret reconcile.
- **Metrics not scraping**: confirm ServiceMonitor exists and Prometheus Operator is running in `monitoring`.
