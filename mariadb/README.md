# MariaDB

Single standalone MariaDB instance from the [Bitnami Helm chart](https://github.com/bitnami/charts/tree/main/bitnami/mariadb) (no operator).

## Structure

```
application.yml            # ArgoCD Application — bitnami/mariadb chart
values.yml                 # Helm values (auth.existingSecret: mariadb-secrets)
kustomization.yml          # Resources applied alongside the chart
namespace.yml              # mariadb namespace
secrets.externalsecret.yml # ESO — pulls credentials from Vault
```

## Vault Setup

Seed credentials before first sync:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/mariadb/credentials \
    root_password='<strong-root-password>' \
    password='<app-password>'
"
```

### Vault Policy

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault policy write mariadb - <<EOF
path \"secret/data/mariadb/*\" {
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
    policies="'"$CURRENT"',mariadb" ttl="1h"'
```

## Verification

```bash
kubectl -n mariadb get pods,pvc
kubectl -n mariadb get externalsecret mariadb-secrets

# Connect (from within cluster)
kubectl -n mariadb run -it --rm mysql-client --image=mariadb:11.8 --restart=Never -- \
  mysql -h mariadb.mariadb.svc.cluster.local -u app -p
```

## Notes

- Secret keys (`mariadb-root-password`, `mariadb-password`) are the names the Bitnami chart requires in `auth.existingSecret`.
- Storage: `kadalu.kadalu-pool-replica3` via `global.defaultStorageClass` (8 Gi default).
- Internal DNS: `mariadb.mariadb.svc.cluster.local:3306`. No ingress — use port-forward or in-cluster DNS.
- Migrating from the old operator-managed instance: data was in PVC `storage-mariadb-0` (not reused); dump and restore if needed, then delete the old PVC and the `mariadb-operator`/`mariadb-operator-crds` Applications and CRDs.
