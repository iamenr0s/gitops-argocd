# Keycloak (Helm)

## Overview
- Deploys Keycloak using the Bitnami Helm chart, managed by Argo CD.
- Ingress exposed via Traefik with Let's Encrypt TLS.
- Admin and Postgres passwords sourced from Vault via External Secrets.

## Files
- `keycloak/application.yml`: Argo CD Application referencing the Bitnami chart and `keycloak/values.yml`.
- `keycloak/values.yml`: Helm values (ingress, secrets, Postgres).
- `keycloak/admin-and-db.externalsecret.yml`: ExternalSecret projecting Vault creds to Secret `keycloak-helm`.
- `keycloak/kustomization.yml`: Includes the ExternalSecret for Argo CD to apply.

## Deploy
- `kubectl apply -f keycloak/application.yml`
- Argo CD will create the `keycloak` namespace, materialize secrets from Vault, and install Keycloak + Postgres.

## Vault
- Path: `secret/keycloak/helm`
- Keys:
  - `admin_password`
  - `postgres_user_password`
  - `postgres_admin_password`

## Vault Setup (kubectl-only)
- Variables:
  - `export TOKEN='<vault_token>'`
  - `export ADMIN_PASSWORD='<admin_password>'`
  - `export POSTGRES_USER_PASSWORD='<postgres_user_password>'`
  - `export POSTGRES_ADMIN_PASSWORD='<postgres_admin_password>'`
- Create read policy:
  - `cat > keycloak-helm.hcl <<'EOF'`
  - `path "secret/data/keycloak/*" { capabilities = ["read"] }`
  - `EOF`
  - `kubectl cp keycloak-helm.hcl vault/vault-0:/tmp/keycloak-helm.hcl -c vault`
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault policy write keycloak-helm /tmp/keycloak-helm.hcl'`
- Bind role to ESO service account (append policy):
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault write auth/kubernetes/role/external-secrets bound_service_account_names="external-secrets" bound_service_account_namespaces="external-secrets" policies="harbor-admin,keycloak-helm" ttl="1h"'`
- Ensure KV v2 and seed secret:
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault secrets enable -path=secret kv-v2 || true'`
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault kv put secret/keycloak/helm admin_password='"$ADMIN_PASSWORD"' postgres_user_password='"$POSTGRES_USER_PASSWORD"' postgres_admin_password='"$POSTGRES_ADMIN_PASSWORD"''`

## Access
- URL: `https://keycloak.apps.k8s.example.com`
- If using chart-generated admin secret instead, check the release notes; with `auth.existingSecret`, the admin password comes from Vault (`keycloak-helm` Secret).

## Notes
- For production, consider external Postgres (`postgresql.enabled=false` and `externalDatabase.*` values) and HA settings.
- Keep Helm version pinned via `targetRevision` and rotate credentials in Vault as needed.
