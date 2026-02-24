# PostgreSQL (Argo CD App)

## Overview
- Deploys PostgreSQL using the Bitnami Helm chart, managed by Argo CD.
- Uses persistent storage via `kadalu.kadalu-pool-replica3`.
- Credentials sourced from Vault via ClusterExternalSecret (CES) to a Secret `postgresql-helm`.
- Chart images are multi-arch (including arm64) and run on ARM64 nodes without extra configuration.

## Files
- `application.yml`: Argo CD Application referencing Bitnami chart `postgresql` and `values.yml`.
- `values.yml`: Helm values (persistence, metrics, existing secret for credentials).
- `kustomization.yml`: includes `namespace.yml`.
- `namespace.yml`: creates the `postgresql` namespace.
- `external-secrets/postgresql.clusterexternalsecret.yml`: ClusterExternalSecret that creates an `ExternalSecret` in `postgresql` which materializes Secret `postgresql-helm`.

## Configuration Highlights
- Database user and DB:
  - `auth.username: app`
  - `auth.database: appdb`
  - `auth.existingSecret: postgresql-helm`
  - Secret keys: `admin-password` and `user-password` (mapped from Vault).
- Persistence:
  - StorageClass: `kadalu.kadalu-pool-replica3`
  - Size: `20Gi`
- Metrics:
  - `metrics.enabled: true`
  - `metrics.serviceMonitor.enabled: true` for Prometheus Operator integration (namespace `monitoring`).

## Vault
- Path: `secret/postgresql/helm`
- Keys:
  - `postgres_admin_password`
  - `postgres_user_password`

## Vault Setup (kubectl-only)
- Variables:
  - `export TOKEN='<vault_token>'`
  - `export POSTGRES_ADMIN_PASSWORD='<admin_password>'`
  - `export POSTGRES_USER_PASSWORD='<user_password>'`
- Create read policy:
  - `cat > postgresql-helm.hcl <<'EOF'`
  - `path "secret/data/postgresql/*" { capabilities = ["read"] }`
  - `EOF`
  - `kubectl cp postgresql-helm.hcl vault/vault-0:/tmp/postgresql-helm.hcl -c vault`
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault policy write postgresql-helm /tmp/postgresql-helm.hcl'`
- Bind role to ESO service account (append policy):
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault write auth/kubernetes/role/external-secrets bound_service_account_names="external-secrets" bound_service_account_namespaces="external-secrets" policies="harbor-admin,postgresql-helm" ttl="1h"'`
- Ensure KV v2 and seed secret:
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault secrets enable -path=secret kv-v2 || true'`
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault kv put secret/postgresql/helm postgres_admin_password='"$POSTGRES_ADMIN_PASSWORD"' postgres_user_password='"$POSTGRES_USER_PASSWORD"''`

## Deploy
- Commit and push; Argo CD will sync to namespace `postgresql`.

## Manual Verification
- `kubectl -n postgresql get pods`
- `kubectl -n postgresql get svc`
- Trigger reconcile: `kubectl -n postgresql annotate externalsecret postgresql-helm reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite`
- Check ClusterExternalSecret: `kubectl describe clusterexternalsecret postgresql-helm`
- Check generated ExternalSecret: `kubectl -n postgresql describe externalsecret postgresql-helm`
- Confirm secret and decode:
  - `kubectl -n postgresql get secret postgresql-helm -o jsonpath='{.data.admin-password}' | base64 -d; echo`
  - `kubectl -n postgresql get secret postgresql-helm -o jsonpath='{.data.user-password}' | base64 -d; echo`

## Notes
- For HA, consider Bitnami PostgreSQL HA or a managed service.
- If you prefer not to expose metrics, set `metrics.enabled=false`.
- To pin a specific image tag, set `image.tag` to a known multi-arch tag.