# Harbor (Argo CD App)

## Overview
- Deploys Harbor via the official Helm chart managed by Argo CD.
- Integrates admin password management using HashiCorp Vault and External Secrets Operator.

## Files
- `harbor/application.yml`: Argo CD Application for Harbor.
- `harbor/values.yml`: Helm values; uses `existingSecretAdminPassword`.
- `harbor/kustomization.yml`: Kustomize overlay.
- `harbor/namespace.yml`: Namespace for `harbor`.
- `harbor/admin-external-secret.yml`: ExternalSecret that syncs admin password from Vault to K8s Secret.

## Prerequisites
- External Secrets CRDs and controller installed.
- Vault deployed and KV v2 mounted at `secret/`.
- Vault Kubernetes auth configured and role `external-secrets` bound to service account `external-secrets`.

## Deploy
- Commit and push; Argo CD syncs Harbor and applies overlay resources.

## Secret Integration (Bash)
- Obtain an admin-capable Vault token:
  - Preferred: `TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d 2>/dev/null || echo)"`
  - If empty, set from Vault UI/CLI: `export TOKEN=<your-admin-token>`
- Ensure KV v2 is mounted at `secret/`:
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault secrets enable -path=secret kv-v2'`
- Seed Harbor admin password in Vault:
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault kv put secret/harbor/admin admin_password="YOUR_STRONG_PASSWORD"'`
- ExternalSecret creates `admin-password` in `harbor` namespace:
  - `kubectl -n harbor describe externalsecret harbor-admin-password`
  - `kubectl -n harbor get secret admin-password -o yaml`
- Harbor values reference the secret:
  - `existingSecretAdminPassword: admin-password`
  - `existingSecretAdminPasswordKey: HARBOR_ADMIN_PASSWORD`

## Verification
- `kubectl -n harbor get pods`
- `kubectl -n harbor exec deploy/harbor-core -- printenv | grep HARBOR_ADMIN_PASSWORD`
- Login to Harbor UI with `admin` and the password stored in Vault.

## Updating
- Bump chart version in `harbor/application.yml`.
- Adjust `harbor/values.yml` for ingress, persistence, storage backends, metrics, and TLS settings.