# authentik (Helm)

## Overview
- Deploys authentik via the official Helm chart, managed by Argo CD.
- Ingress exposed via Traefik with Let's Encrypt TLS.
- Secrets are sourced from Vault via ExternalSecrets, avoiding plaintext in `values.yml`.

## Files
- `authentik/application.yml`: Argo CD Application referencing the `authentik` chart and `authentik/values.yml`.
- `authentik/values.yml`: Helm values (ingress, env, bundled PostgreSQL auth via existing secret).
- `authentik/kustomization.yml`: Includes `namespace.yml` and `secrets.externalsecret.yml`.
- `authentik/secrets.externalsecret.yml`: ExternalSecret in `authentik` that materializes Secret `authentik-helm`.

## Deploy
- `kubectl apply -f authentik/application.yml`
- Argo CD will create the `authentik` namespace, materialize secrets from Vault, and install authentik.

## Vault
- Path: `secret/authentik/helm`
- Keys:
  - `secret_key` (cookie signing key; generate 50+ chars)
  - `postgres_password` (DB user password)
  - `postgres_admin_password` (DB admin password)
  - `replication_password` (DB replication user password)

## Vault Setup (kubectl-only)
- Variables:
  - `export TOKEN='<vault_token>'`
  - `export SECRET_KEY='<secure_random>'`
  - `export POSTGRES_PASSWORD='<db_user_password>'`
  - `export POSTGRES_ADMIN_PASSWORD='<db_admin_password>'`
  - `export REPLICATION_PASSWORD='<replication_password>'`
- Create read policy:
  - `cat > authentik-helm.hcl <<'EOF'`
  - `path "secret/data/authentik/*" { capabilities = ["read"] }`
  - `EOF`
  - `kubectl cp authentik-helm.hcl vault/vault-0:/tmp/authentik-helm.hcl -c vault`
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault policy write authentik-helm /tmp/authentik-helm.hcl'`
- Bind role to ESO service account (append policy):
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault write auth/kubernetes/role/external-secrets bound_service_account_names="external-secrets" bound_service_account_namespaces="external-secrets" policies="authentik-helm" ttl="1h"'`
- Ensure KV v2 and seed secret:
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault secrets enable -path=secret kv-v2 || true'`
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault kv put secret/authentik/helm secret_key='"$SECRET_KEY"' postgres_password='"$POSTGRES_PASSWORD"' postgres_admin_password='"$POSTGRES_ADMIN_PASSWORD"' replication_password='"$REPLICATION_PASSWORD"''`

## Access
- URL: `https://authentik.apps.k8s.enros.me`
- Initial setup: `https://authentik.apps.k8s.enros.me/if/flow/initial-setup/` (note trailing slash)

## Notes
- Chart version pinned via `targetRevision: 2026.2.0`.
- For production, consider external PostgreSQL (set `postgresql.enabled=false` and configure `authentik.postgresql.*` + env from secret).
- Rotate credentials regularly in Vault; ExternalSecrets refresh hourly by default.

## Manual Verification
- Check ExternalSecret: `kubectl -n authentik describe externalsecret authentik-helm`
- Force reconcile: `kubectl -n authentik annotate externalsecret authentik-helm reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite`
- Confirm Secret and decode:
  - `kubectl -n authentik get secret authentik-helm -o jsonpath='{.data.secret_key}' | base64 -d; echo`
  - `kubectl -n authentik get secret authentik-helm -o jsonpath='{.data.password}' | base64 -d; echo`

## Troubleshooting
- 404 on initial setup: ensure URL includes trailing `/` and pods are healthy.
- Secret not found on first boot: re-sync app; the deployment will pick up the secret after reconcile.
- DB connection issues: check Postgres pod logs and credentials in Secret `authentik-helm`.

