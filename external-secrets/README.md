# External Secrets (Argo CD App)

## Overview
- Deploys External Secrets Operator using two Argo CD Applications: one for CRDs and one for the controller.
- Safely installs and upgrades CRDs ahead of the controller using sync waves.
- Manages `ExternalSecret`, `SecretStore`, `ClusterSecretStore`, `ClusterExternalSecret`, and related CRDs.

## Files
- `external-secrets/external-secrets-crds.yml`: installs CRDs only (`installCRDs: true`, components disabled).
- `external-secrets/external-secrets-controller.yml`: deploys the operator with your Helm values.
- `external-secrets/values.yml`: Helm values for the controller (CRDs disabled here).
- `external-secrets/postgresql.clusterexternalsecret.yml`: CES for PostgreSQL (`postgresql-helm`).

## Chart Version
- Chart `targetRevision: 1.3.2` is set in both application manifests.
- Bump both `targetRevision` fields together when upgrading.

## Configuration Highlights
- Controller `values.yml` sets `installCRDs: false` because CRDs are handled by the CRD application.
- Webhook and certificate management are created by the controller (`webhook.create: true`, `certController.create: true`).
- Sync order is enforced via annotations: CRDs wave `-5`, controller wave `0`.
- Sync options include `CreateNamespace=true` and `ApplyOutOfSyncOnly=true` for efficient syncs.
- CRD application uses `ServerSideApply=true` and `Prune=false` to avoid accidental CRD deletions.

## Deploy
- Commit and push; Argo CD creates the `external-secrets` namespace and syncs the apps.
- The controller runs with `replicaCount: 1` by default; adjust in `values.yml` if needed.
- If applying manually, install CRDs first:
  - `helm repo add external-secrets https://charts.external-secrets.io`
  - `helm repo update`
  - `helm upgrade --install external-secrets-crds external-secrets/external-secrets --namespace external-secrets --create-namespace --version 1.3.2 --set installCRDs=true --set webhook.enabled=false --set certController.enabled=false --set replicaCount=0`
  - `kubectl wait --for=condition=Established crd clustersecretstores.external-secrets.io secretstores.external-secrets.io externalsecrets.external-secrets.io clusterexternalsecrets.external-secrets.io --timeout=60s`
  - `kubectl apply -k external-secrets/`

## Using Providers (Vault example)
- Create a `ClusterSecretStore` for Vault at `external-secrets/clustersecretstore-vault.yml` (apiVersion `external-secrets.io/v1`).
- Configure Kubernetes auth. Obtain an admin-capable token first:
  - Prefer: `TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d 2>/dev/null || echo)"`; if empty, set `TOKEN` from Vault UI/CLI: `export TOKEN=<your-admin-token>`
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault auth enable kubernetes || true'`
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc" kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt'`
- Create read policy:
  - `cat > harbor-admin.hcl <<'EOF'
path "secret/data/harbor/admin" {
  capabilities = ["read"]
}
EOF`
  - `kubectl cp harbor-admin.hcl vault/vault-0:/tmp/harbor-admin.hcl -c vault`
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault policy write harbor-admin /tmp/harbor-admin.hcl'`
- Bind role to ESO service account:
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault write auth/kubernetes/role/external-secrets bound_service_account_names="external-secrets" bound_service_account_namespaces="external-secrets" policies="harbor-admin" ttl="1h"'`
- Mount KV v2 and seed secret:
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault secrets enable -path=secret kv-v2'`
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault kv put secret/harbor/admin admin_password="YOUR_STRONG_PASSWORD"'`

## Verification
- `kubectl -n external-secrets get pods`
- `kubectl get crds | grep external-secrets`
- `kubectl -n external-secrets logs deploy/external-secrets`
- `kubectl get clustersecretstore vault-backend`
- `kubectl describe clusterexternalsecret postgresql-helm`
- `kubectl -n postgresql describe externalsecret postgresql-helm`
- `kubectl -n postgresql get secret postgresql-helm -o yaml`

## Troubleshooting
- CRDs missing: ensure the CRD application is synced and still configured with `installCRDs: true`.
- Webhook/cert errors: the chart’s cert controller manages self‑signed certificates; enable `webhook.certManager.enabled` if you prefer cert‑manager and set `issuerRef`.
- Provider failures: inspect controller logs and validate provider credentials/configuration.
- Store NotReady: ensure the controller is installed (deployment `external-secrets`) and the ServiceAccount `external-secrets` exists in namespace `external-secrets`.
- Invalid provider config: verify `server` is a plain URL (e.g., `http://vault.vault.svc:8200` without backticks) and Vault Kubernetes auth role `external-secrets` is bound to the SA in `external-secrets`.

## Updating
- Update chart version in both application manifests and sync.
- Extend `values.yml` for metrics, service monitors, leader election, or resource tuning as needed.
