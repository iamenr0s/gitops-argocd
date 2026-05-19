# certctl

Deploys [certctl-io/certctl](https://github.com/certctl-io/certctl) via Helm (chart from upstream repo), managed by Argo CD. Provides a self-hosted certificate lifecycle management platform with a web UI and DaemonSet agent. Secrets (API key, database password) are sourced from Vault via External Secrets.

## Structure

```
application.yml                        # ArgoCD Application — chart certctl@v2.1.7 + valuesFrom
values.yml                             # Helm values (ingress, agent, resources)
kustomization.yml                      # Includes namespace.yml
namespace.yml                          # certctl namespace
argocd-helm-values.externalsecret.yml  # ESO — creates Secret certctl-helm-values in argocd namespace
```

## Prepare External PostgreSQL

```bash
kubectl -n postgresql exec -it sts/postgresql -- bash
psql -U postgres
```

```sql
CREATE USER certctl WITH PASSWORD '<strong-password>';
CREATE DATABASE certctl OWNER certctl TEMPLATE template0 ENCODING 'UTF8';
GRANT ALL PRIVILEGES ON DATABASE certctl TO certctl;
```

Store `<strong-password>` in Vault at `secret/certctl/config` as `db_password` (see Vault Setup below).

## Vault Setup

Seed credentials before first sync:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/certctl/config \
    api_key='<random-api-key>' \
    db_password='<strong-password>'
"
```

### Vault Policy

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault policy write certctl - <<EOF
path \"secret/data/certctl/*\" {
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
    policies="'"$CURRENT"',certctl" ttl="1h"'
```

### Apply argocd ExternalSecret

The `argocd-helm-values.externalsecret.yml` lives in the `argocd` namespace and must be applied once before the first ArgoCD sync so the `certctl-helm-values` Secret is available at render time:

```bash
kubectl apply -f certctl/argocd-helm-values.externalsecret.yml
```

## Deploy

```bash
kubectl apply -f certctl/application.yml
```

On first deploy, wait ~30s for ESO to reconcile `certctl-helm-values` in the `argocd` namespace before Argo CD renders the chart. If the sync fails with a missing Secret error, re-sync:

```bash
argocd app sync certctl
```

## Verification

```bash
# Pods (server + agent DaemonSet)
kubectl -n certctl get pods

# ExternalSecret synced (argocd namespace)
kubectl -n argocd describe externalsecret certctl-helm-values

# Force reconcile
kubectl -n argocd annotate externalsecret certctl-helm-values \
  reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite

# Confirm helm-values Secret exists
kubectl -n argocd get secret certctl-helm-values

# TLS certificate issued
kubectl -n certctl get certificate

# Ingress
kubectl -n certctl get ingress
```

## Notes

- URL: `https://certctl.apps.k8s.enros.me`
- Chart source: `https://github.com/certctl-io/certctl.git` at `deploy/helm/certctl`, pinned to `v2.1.7`.
- API key and database URL are injected via `helm.valuesFrom` referencing Secret `certctl-helm-values` in the `argocd` namespace.
- Uses external PostgreSQL (`postgresql.enabled: false`); service DNS: `postgresql-postgresql.postgresql.svc.cluster.local:5432`.
- Agent runs as DaemonSet, discovers certificates on every node.
- TLS managed by cert-manager via `letsencrypt-production`.

## Troubleshooting

- **First sync fails (missing Secret)**: `certctl-helm-values` in `argocd` may not exist yet — wait ~30s for ESO then re-sync.
- **ExternalSecret not ready**: confirm Vault policy covers `secret/data/certctl/*` and ESO role includes `certctl`.
- **DB connection refused**: verify PostgreSQL user/database were created and password matches Vault secret.
- **Agent CrashLoop**: check `keyDir` permissions; agent runs as non-root UID 1000.
- **TLS cert pending**: confirm cert-manager and Cloudflare credentials are healthy.
