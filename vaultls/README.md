# VaulTLS

Deploys [VaulTLS](https://github.com/7ritn/VaulTLS) — a self-hosted internal certificate authority and TLS certificate manager — via Kustomize, managed by Argo CD. Data (CAs, certificates, CRLs, SQLite DB) persists under `/app/data` via PVC. Ingress via Traefik with Let's Encrypt TLS; API/DB encryption secrets sourced from Vault via External Secrets.

## Structure

```
application.yml              # ArgoCD Application — kustomize path
kustomization.yml            # Aggregates namespace, pvc, secrets, deployment, service, ingress
namespace.yml                # vaultls namespace
pvc.yml                      # Persistent /app/data volume (1Gi)
secrets.externalsecret.yml   # ESO — creates Secret vaultls-app from Vault
deployment.yml                # VaulTLS Deployment
service.yml                  # ClusterIP service on port 80
ingress.yml                  # Traefik ingress with TLS
```

## Vault Setup

Seed credentials before first sync:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/vaultls/helm \
    api_secret='$(openssl rand -base64 32)' \
    db_secret='$(openssl rand -base64 32)'
"
```

### Vault Policy

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault policy write vaultls - <<EOF
path \"secret/data/vaultls/*\" {
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
    policies="'"$CURRENT"',vaultls" ttl="1h"'
```

## Deploy

```bash
kubectl apply -f vaultls/application.yml
# or
argocd app sync vaultls --prune --refresh
```

## Verification

```bash
# ExternalSecret synced
kubectl -n vaultls describe externalsecret vaultls-app

# Force reconcile
kubectl -n vaultls annotate externalsecret vaultls-app \
  reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite

# App
kubectl -n vaultls get pods -l app=vaultls
kubectl -n vaultls logs deploy/vaultls

# PVC bound
kubectl -n vaultls get pvc vaultls-data
```

## Notes

- URL: `https://vaultls.apps.k8s.enros.me`
- Image: `ghcr.io/7ritn/vaultls:latest`
- No external database required — VaulTLS stores certificates and its SQLite database under `/app/data`; `VAULTLS_DB_SECRET` encrypts that data at rest.
- The container runs nginx (port 80, serving the Vue frontend and proxying `/api/` to the Rust backend) plus a CRL-only static file server on port 2277; the Rust backend itself listens on `127.0.0.1:3737` only and is not exposed directly. `service.yml`/`ingress.yml` target port 80.
- OIDC login and ACME CA functionality are not configured — the app defaults to local username/password auth. Add `VAULTLS_OIDC_*` / `VAULTLS_ACME_ENABLED` env vars to `deployment.yml` if needed later.

## Troubleshooting

- **First-login setup**: on first boot VaulTLS creates the initial admin account via its own onboarding flow — check `kubectl -n vaultls logs deploy/vaultls` for the setup URL/instructions.
- **Secret not ready at first boot**: `kubectl rollout restart deploy/vaultls -n vaultls`.
- **Data not persisting across restarts**: confirm the PVC is bound: `kubectl -n vaultls get pvc vaultls-data`.
