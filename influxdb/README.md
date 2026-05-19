# InfluxDB 2

Deploys InfluxDB 2 via Helm with persistent storage and Traefik ingress. Admin credentials provided via External Secrets backed by Vault.

## Structure

```
application.yml                    # ArgoCD Application — chart influxdb2
values.yml                         # Helm values (storage, ingress, admin user)
kustomization.yml                  # Includes influxdb-auth.externalsecret.yml
influxdb-auth.externalsecret.yml   # ESO — creates Secret influxdb-influxdb2-auth from Vault
```

## Vault Setup

Seed credentials before first sync:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/influxdb/admin \
    admin_password='<admin-password>' \
    admin_token='<admin-token>'
"
```

### Vault Policy

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault policy write influxdb - <<EOF
path \"secret/data/influxdb/*\" {
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
    policies="'"$CURRENT"',influxdb" ttl="1h"'
```

## Deploy

Commit and push — Argo CD will sync the app to namespace `influxdb`.

## Verification

```bash
# Pods
kubectl -n influxdb get pods

# ExternalSecret synced
kubectl -n influxdb describe externalsecret influxdb-influxdb2-auth

# Force reconcile
kubectl -n influxdb annotate externalsecret influxdb-influxdb2-auth \
  reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite

# Decode credentials
kubectl -n influxdb get secret influxdb-influxdb2-auth \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl -n influxdb get secret influxdb-influxdb2-auth \
  -o jsonpath='{.data.admin-token}' | base64 -d; echo
```

## Notes

- URL: `https://influxdb.apps.k8s.enros.me`
- Storage class: `kadalu.kadalu-pool-replica3`.
- Admin user uses `existingSecret: influxdb-influxdb2-auth` with keys `admin-password` and `admin-token`.

## Troubleshooting

- **Secret not syncing**: ensure Vault policy covers `secret/data/influxdb/*` and ESO role includes `influxdb`.
- **Pod pending**: verify storage class and PVC binding.
- **404/ingress issues**: confirm Traefik is running and certificate is issued.
