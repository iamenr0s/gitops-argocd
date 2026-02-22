# InfluxDB 2 (Argo CD App)

## Overview
- Deploys InfluxDB 2 via Helm with persistent storage and Traefik ingress.
- Admin credentials provided via ExternalSecret backed by Vault.

## Files
- `application.yml`: Argo CD Application for chart `influxdb2`.
- `values.yaml`: Helm values (storage, ingress, admin user).
- `kustomization.yml`: includes `influxdb-auth.externalsecret.yml`.
- `influxdb-auth.externalsecret.yml`: ExternalSecret that creates `influxdb-influxdb2-auth` from Vault.

## Configuration Highlights
- Persistence enabled using storage class `kadalu.kadalu-pool-replica3`.
- Ingress enabled with TLS (`influxdb.apps.k8s.example.com`) via Traefik and cert-manager annotations.
- Admin user uses `existingSecret: influxdb-influxdb2-auth` with keys `admin-password` and `admin-token`.
- ExternalSecret maps Vault KV v2 `secret/influxdb/admin` properties `admin_password` and `admin_token` to secret keys.

## Deploy
- Commit and push; Argo CD will sync the app to namespace `influxdb`.

## Vault Setup (kubectl-only)
- Variables:
  - `export TOKEN='<vault_token>'`
  - `export ADMIN_PASSWORD='<admin_password>'`
  - `export ADMIN_TOKEN='<admin_token>'`
- Create read policy:
  - `cat > influxdb-admin.hcl <<'EOF'`
  - `path "secret/data/influxdb/admin" { capabilities = ["read"] }`
  - `EOF`
  - `kubectl cp influxdb-admin.hcl vault/vault-0:/tmp/influxdb-admin.hcl -c vault`
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault policy write influxdb-admin /tmp/influxdb-admin.hcl'`
- Bind role to ESO service account:
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault write auth/kubernetes/role/external-secrets bound_service_account_names="external-secrets" bound_service_account_namespaces="external-secrets" policies="harbor-admin,influxdb-admin" ttl="1h"'`
- Ensure KV v2 and seed secret:
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault secrets enable -path=secret kv-v2 || true'`
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault kv put secret/influxdb/admin admin_password='"$ADMIN_PASSWORD"' admin_token='"$ADMIN_TOKEN"''`

## Manual Verification
- Trigger reconcile: `kubectl -n influxdb annotate externalsecret influxdb-influxdb2-auth reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite`
- Check ExternalSecret: `kubectl -n influxdb describe externalsecret influxdb-influxdb2-auth`
- Controller logs: `kubectl -n external-secrets logs deploy/external-secrets`
- Confirm secret: `kubectl -n influxdb get secret influxdb-influxdb2-auth -o yaml`
- Decode values:
  - `kubectl -n influxdb get secret influxdb-influxdb2-auth -o jsonpath='{.data.admin-password}' | base64 -d; echo`
  - `kubectl -n influxdb get secret influxdb-influxdb2-auth -o jsonpath='{.data.admin-token}' | base64 -d; echo`

## Troubleshooting
- Could not get secret data from provider: ensure Vault policy allows `secret/data/influxdb/admin` and ESO role includes `influxdb-admin`.
- Pod pending: verify storage class and PVC binding.
- 404/Ingress issues: confirm Traefik and certificate issuance.

