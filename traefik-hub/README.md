# Traefik Hub

Deploys the Traefik Hub agent via the `traefik-hub` Helm chart (v4.2.0), managed by Argo CD. The agent connects to the Traefik Hub platform using a token stored in Vault.

## Structure

```
application.yml                     # Argo CD Application — installs Traefik Hub chart + local overlay
values.yml                          # Helm values (service type, providers, token secret name)
kustomization.yml                   # Includes namespace.yml, hub-agent-token.externalsecret.yml
namespace.yml                       # traefik-hub namespace
hub-agent-token.externalsecret.yml  # ESO — creates Secret hub-agent-token from Vault (sync-wave: -1)
```

## Sync Wave Ordering

| Wave | Resource |
|------|----------|
| -1   | `hub-agent-token` ExternalSecret (ESO must be ready) |
| 0    | Helm chart: Traefik Hub agent |

On the very first sync, ensure ESO has reconciled the `hub-agent-token` Secret before the Hub agent starts. If the agent fails with a token error, force reconcile the ExternalSecret:

```bash
kubectl -n traefik-hub annotate externalsecret hub-agent-token \
  reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite
```

## Vault Setup

Seed the Hub platform token before deploying:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/traefik-hub/token \
    token='<hub-platform-token>'
"
```

Obtain the Hub platform token from the [Traefik Hub dashboard](https://hub.traefik.io).

### Vault Policy

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault policy write traefik-hub - <<EOF
path \"secret/data/traefik-hub/*\" {
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
    policies="'"$CURRENT"',traefik-hub" ttl="1h"'
```

## Deploy

Commit and push — Argo CD syncs the `traefik-hub` Application which applies the ExternalSecret (wave -1) then the Helm chart (wave 0).

```bash
git add traefik-hub/ && git commit -m "feat(traefik-hub): add initial configuration" && git push
```

## Verification

```bash
# ExternalSecret synced
kubectl -n traefik-hub describe externalsecret hub-agent-token

# Token secret exists
kubectl -n traefik-hub get secret hub-agent-token -o jsonpath='{.data.token}' | base64 -d | wc -c

# Hub agent pods running
kubectl -n traefik-hub get pods

# Argo CD Application healthy
argocd app get traefik-hub
```

## Notes

- `hubTokenSecretName` in `values.yml` points to the `hub-agent-token` Secret materialised by the ExternalSecret.
- The agent exposes a LoadBalancer Service on ports 80 (web) and 443 (websecure).
- Provider configuration (`kubernetesCRD`, `kubernetesIngress`) inherits from the cluster default; configure namespaces and label selectors in `values.yml` if needed.
