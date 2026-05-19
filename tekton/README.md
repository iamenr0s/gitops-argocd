# Tekton Pipelines

Deploys Tekton Pipelines and Tekton Dashboard from upstream manifests via Kustomize, managed by Argo CD. Dashboard exposed via Traefik Ingress. Git credentials sourced from Vault via External Secrets.

## Structure

```
pipelines-manifests.application.yml      # ArgoCD Application — Pipelines latest release
pipelines-manifests/kustomization.yml    # References upstream latest pipeline manifest
tekton-dashboard.manifests.application.yml  # ArgoCD Application — Dashboard latest release
dashboard-manifests/kustomization.yml    # References upstream latest dashboard manifest
dashboard.ingress.yml                    # Traefik Ingress for Dashboard
git-auth.externalsecret.yml              # ESO — creates Secret tekton-git-auth from Vault
kustomization.yml                        # Includes ExternalSecret and Ingress
```

## Vault Setup

Seed Git credentials before first sync:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/tekton/git \
    username='<github-bot-user>' \
    password='<personal-access-token>'
"
```

### Vault Policy

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault policy write tekton - <<EOF
path \"secret/data/tekton/*\" {
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
    policies="'"$CURRENT"',tekton" ttl="1h"'
```

## Deploy

```bash
kubectl apply -f tekton/pipelines-manifests.application.yml
kubectl apply -f tekton/tekton-dashboard.manifests.application.yml
```

## Verification

```bash
# CRDs installed
kubectl get crds | grep tekton

# Controller pods
kubectl -n tekton-pipelines get pods -o wide

# Webhook service
kubectl -n tekton-pipelines get svc

# Dashboard ingress
kubectl -n tekton-pipelines get ingress tekton-dashboard -o wide

# Git auth Secret
kubectl -n tekton-pipelines get secret tekton-git-auth -o yaml
```

## Notes

- Dashboard URL: `https://tekton.apps.k8s.enros.me`
- Apps track `latest` upstream releases; pin versions by changing remote URLs to `previous/vX.Y.Z/release.yaml`.
- Tekton reads Secrets associated with a Run's ServiceAccount; Secrets annotated with `tekton.dev/git-0: https://github.com` provide `~/.gitconfig`.
- Validating webhooks are deleted by default patches to avoid transient TLS issues on first install.

## Troubleshooting

- **CRDs not installing**: check pipelines app sync status.
- **Dashboard 503**: ensure `tekton-pipelines` namespace exists and dashboard pods are running.
- **Git auth not working**: confirm Secret `tekton-git-auth` is type `kubernetes.io/basic-auth` with annotation `tekton.dev/git-0: https://github.com`.
- **Webhook TLS errors**: expected on first install — validating webhooks are removed by default patches.
