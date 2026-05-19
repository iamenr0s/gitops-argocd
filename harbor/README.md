# Harbor

Deploys Harbor via the official Helm chart, managed by Argo CD. Admin password sourced from Vault via External Secrets.

## Structure

```
application.yml                  # ArgoCD Application — chart + values.yml
values.yml                       # Helm values (existingSecretAdminPassword, ingress, persistence, imagePullSecrets)
kustomization.yml                # Kustomize overlay
namespace.yml                    # harbor namespace
admin-external-secret.yml        # ESO — creates Secret admin-password from Vault
dockerhub-external-secret.yml    # ESO — creates dockerconfigjson Secret harbor-dockerhub from Vault
```

## Vault Setup

Seed credentials before first sync:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

# Admin password
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/harbor/admin \
    admin_password='<strong-password>'
"

# Docker Hub credentials (used as imagePullSecret to bypass anonymous pull rate limit)
# Create a Personal Access Token at https://hub.docker.com/settings/security with "Public Repo Read-only" scope.
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/harbor/dockerhub \
    username='<dockerhub-username>' \
    token='<dockerhub-pat>'
"
```

### Vault Policy

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault policy write harbor-admin - <<EOF
path \"secret/data/harbor/*\" {
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
    policies="'"$CURRENT"',harbor-admin" ttl="1h"'
```

## Deploy

Commit and push — Argo CD syncs Harbor and applies the overlay resources.

## Verification

```bash
# Pods
kubectl -n harbor get pods

# ExternalSecret synced
kubectl -n harbor describe externalsecret harbor-admin-password

# Admin password env
kubectl -n harbor exec deploy/harbor-core -- printenv | grep HARBOR_ADMIN_PASSWORD
```

## Notes

- `values.yml` sets `existingSecretAdminPassword: admin-password` and `existingSecretAdminPasswordKey: HARBOR_ADMIN_PASSWORD`.
- Login to Harbor UI with `admin` and the password stored in Vault.

## Notes on architecture and image pulls

- The chart references custom multi-arch images at `docker.io/iamenr0s/harbor-*:latest`. The cluster nodes are arm64; the official `goharbor/*` images are amd64-only, which is why custom images exist.
- `imagePullPolicy: Always` is set so kubelet re-resolves the manifest list on every pod start and selects the arm64 sub-manifest. Without this, containerd may serve a stale amd64 snapshot cached under the same manifest-list digest, producing `exec format error` crashes.
- An authenticated `imagePullSecret` (`harbor-dockerhub`) is required because anonymous Docker Hub pulls are capped at 100/6h per egress IP — the cluster easily exhausts that during a Harbor rollout. With a Docker Hub PAT the limit becomes 200/6h (free) or unlimited (Pro).

## Troubleshooting

- **Admin password not updating**: force ExternalSecret reconcile then restart core:

```bash
kubectl -n harbor annotate externalsecret harbor-admin-password \
  reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite
kubectl -n harbor rollout restart deploy/harbor-core
```

- **Pods not starting**: check PVC binding: `kubectl -n harbor get pvc`.
- **Registry push/pull fails**: verify TLS certificates: `kubectl -n harbor get certificate`.
- **Login rejected**: confirm `HARBOR_ADMIN_PASSWORD` in Secret `admin-password` matches Vault.
- **Pods crash with `exec format error`**: arm64 nodes are running cached amd64 layers. Verify `imagePullPolicy: Always` is in the Deployment and that `harbor-dockerhub` imagePullSecret is present and synced. Then restart the workload to force a fresh pull:
  ```bash
  kubectl -n harbor rollout restart deploy,statefulset
  ```
- **`ImagePullBackOff` with `toomanyrequests`**: anonymous Docker Hub rate limit hit. Confirm Vault is seeded at `secret/harbor/dockerhub`, force ESO reconcile, then restart pods:
  ```bash
  kubectl -n harbor annotate externalsecret harbor-dockerhub \
    reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite
  kubectl -n harbor get secret harbor-dockerhub -o jsonpath='{.type}'  # expect: kubernetes.io/dockerconfigjson
  kubectl -n harbor rollout restart deploy,statefulset
  ```
  If the limit is already exhausted, wait until the 6-hour window resets — current usage is visible in the `ratelimit-remaining` header from `https://registry-1.docker.io/v2/iamenr0s/harbor-core/manifests/latest`.
