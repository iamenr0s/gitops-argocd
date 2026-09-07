# Monitoring Stack

Deploys `kube-prometheus-stack` (Prometheus, Alertmanager, Grafana, exporters) via Helm. Grafana admin credentials sourced from Vault via External Secrets.

## Structure

```
application.yml                              # ArgoCD Application — chart + local overlay
values.yml                                   # Helm values (ingress, operator, cert-manager, webhooks)
kustomization.yml                            # Includes namespace.yml and the ExternalSecrets/ConfigMaps below
namespace.yml                                # monitoring namespace
grafana-auth.externalsecret.yml              # ESO — creates Secret grafana-secret from Vault
influxdb-datasource.externalsecret.yml       # ESO — creates Secret influxdb-datasource (grafana_datasource: "1"), provisions the InfluxDB Grafana datasource using the existing influxdb/admin token
x509-cert-check.grafana-dashboard.configmap.yml  # Grafana dashboard (grafana_dashboard: "1") for telegraf's x509_cert SSL expiry data
```

## Vault Setup

Seed credentials before first sync:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/grafana/admin \
    admin_user='admin' \
    admin_password='<strong-password>'
"
```

### Vault Policy

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault policy write grafana - <<EOF
path \"secret/data/grafana/*\" {
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
    policies="'"$CURRENT"',grafana" ttl="1h"'
```

### InfluxDB datasource (no new Vault setup)

`influxdb-datasource.externalsecret.yml` reuses the existing `influxdb/admin` Vault path and `admin_token` property already seeded for the `influxdb` app — the ESO role's `influxdb` policy already grants read access, so no new policy/role changes are needed here. It renders a Secret labeled `grafana_datasource: "1"`, which Grafana's sidecar auto-provisions as a datasource (uid `influxdb`, Flux query language, org `influxdata`, bucket `default`).

## Deploy

Commit and push — Argo CD will sync to namespace `monitoring`.

## Verification

```bash
# Pods and ingress
kubectl -n monitoring get pods
kubectl -n monitoring get ingress

# ExternalSecret synced
kubectl -n monitoring describe externalsecret grafana-secret

# Force reconcile
kubectl -n monitoring annotate externalsecret grafana-secret \
  reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite

# Decode credentials
kubectl -n monitoring get secret grafana-secret \
  -o jsonpath='{.data.admin-user}' | base64 -d; echo
kubectl -n monitoring get secret grafana-secret \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

## Notes

- Grafana: `https://grafana.apps.k8s.enros.me`
- Prometheus: `https://prometheus.apps.k8s.enros.me`
- Alertmanager: `https://alertmanager.apps.k8s.enros.me`
- Grafana expects Secret `grafana-secret` with keys `admin-user` and `admin-password`.

## Troubleshooting

- **Secret not syncing**: ensure Vault policy covers `secret/data/grafana/*` and ESO role includes `grafana`.
- **Long sync on hooks**: confirm cert-manager is installed and webhook patch jobs are disabled in values.
- **CRD errors**: `ignoreDifferences` is configured; manage CRDs via chart or dedicated app if needed.
