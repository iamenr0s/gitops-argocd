# MariaDB Operator

Deploys the [mariadb-operator](https://github.com/mariadb-operator/mariadb-operator) and a managed MariaDB instance.

## Structure

```
mariadb-operator-crds.yml       # ArgoCD Application — CRDs only (sync-wave -5)
mariadb-operator-controller.yml # ArgoCD Application — operator controller (sync-wave 0)
values.yml                      # Helm values for the operator (crds.enabled: false)
kustomization.yml               # Resources applied alongside the chart
namespace.yml                   # mariadb namespace
secrets.externalsecret.yml      # ESO — pulls credentials from Vault
mariadb-instance.yml            # MariaDB CR — managed instance (sync-wave 1)
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

## Bootstrap

Apply CRDs first, then the controller Application:

```bash
kubectl apply -f mariadb/mariadb-operator-crds.yml
# wait ~30s for CRDs to register
kubectl apply -f mariadb/mariadb-operator-controller.yml
```

## Verification

```bash
# Operator pods
kubectl -n mariadb get pods

# MariaDB instance status
kubectl -n mariadb get mariadb mariadb

# Check ExternalSecret synced
kubectl -n mariadb get externalsecret mariadb-secrets

# Connect (from within cluster)
kubectl -n mariadb run -it --rm mysql-client --image=mariadb:11.8 --restart=Never -- \
  mysql -h mariadb.mariadb.svc.cluster.local -u app -p

# Internal DNS
# mariadb.mariadb.svc.cluster.local:3306
```

## Notes

- Storage: `kadalu.kadalu-pool-replica3` (10 Gi)
- MariaDB internal DNS: `mariadb.mariadb.svc.cluster.local:3306`
- No HTTP ingress — MariaDB is a TCP service. Use port-forward or in-cluster DNS for access.
- To expose externally, configure a Traefik `IngressRouteTCP` with a dedicated TCP entrypoint on port 3306.
