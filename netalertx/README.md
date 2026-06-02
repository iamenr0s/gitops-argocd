# NetAlertX

Deploys NetAlertX (network visibility and asset discovery) via Kustomize, managed by Argo CD. Runs with `hostNetwork` for network scanning and persists config/database under `/data` via PVC.

Upstream: https://github.com/netalertx/NetAlertX

## Structure

```
application.yml      # Argo CD Application — kustomize path
kustomization.yml    # Aggregates namespace, pvc, externalsecret, deployment, service, ingress
namespace.yml        # netalertx namespace
pvc.yml              # Persistent /data volume
secrets.externalsecret.yml # ESO — creates Secret netalertx-app from Vault (optional)
deployment.yml       # NetAlertX Deployment (hostNetwork + required capabilities)
service.yml          # ClusterIP service on port 20211
ingress.yml          # Traefik ingress with TLS
```

## Secret Management

NetAlertX does not require a Kubernetes Secret to start. Most configuration is stored under `/data` after initial setup.

An optional External Secret is included to source `APP_CONF_OVERRIDE` from Vault (useful when it contains sensitive values such as API tokens).

- Vault path: `netalertx/helm`
- Property: `app_conf_override` (value is the JSON for `APP_CONF_OVERRIDE`)

## Vault Setup

Seed the Vault key before first sync:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/netalertx/helm \
    app_conf_override='{\"API_TOKEN\":\"<random_token>\",\"WEBHOOK_SECRET\":\"<random_secret>\"}'
"
```

### Vault Policy

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault policy write netalertx - <<EOF
path \"secret/data/netalertx/*\" {
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
    policies="'"$CURRENT"',netalertx" ttl="1h"'
```
## Deploy

```bash
kubectl apply -f netalertx/application.yml
# or
argocd app sync netalertx --prune --refresh
```

## Verification

```bash
kubectl -n netalertx get pods -o wide
kubectl -n netalertx get pvc netalertx-data
kubectl -n netalertx get svc netalertx -o wide
kubectl -n netalertx get ingress netalertx -o wide
kubectl -n netalertx logs deploy/netalertx --tail=200
```

## Notes

- URL: `https://netalertx.apps.k8s.enros.me`
- Image: `jokobsk/netalertx:latest`
- This deployment enables `hostNetwork` and Linux capabilities (`NET_ADMIN`, `NET_RAW`, `NET_BIND_SERVICE`) for scanning features; ensure your cluster policies allow this.
