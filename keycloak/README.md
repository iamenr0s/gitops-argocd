# KeycloakX (Helm)

## Overview
- Deploys Keycloak using the codecentric `keycloakx` Helm chart (official Keycloak image), managed by Argo CD.
- Ingress exposed via Traefik with Let's Encrypt TLS.
- Admin password sourced from Vault via a namespaced ExternalSecret; Keycloak uses the external PostgreSQL deployed in this repo.

## Files
- `keycloak/application.yml`: Argo CD Application referencing the codecentric `keycloakx` chart and `keycloak/values.yml`.
- `keycloak/values.yml`: Helm values (ingress, secrets, external database).
- `keycloak/kustomization.yml`: Includes `namespace.yml` and `admin-and-db.externalsecret.yml`.
- `keycloak/admin-and-db.externalsecret.yml`: ExternalSecret in `keycloak` that materializes Secret `keycloak-helm`.

## Deploy
- `kubectl apply -f keycloak/application.yml`
- Argo CD will create the `keycloak` namespace, materialize secrets from Vault, and install Keycloak configured to use the external PostgreSQL app.

## Vault
- Path: `secret/keycloak/helm`
- Keys:
  - `admin_password`
  - `postgres_user_password`

## Vault Setup (kubectl-only)
- Variables:
  - `export TOKEN='<vault_token>'`
  - `export ADMIN_PASSWORD='<admin_password>'`
  - `export POSTGRES_USER_PASSWORD='<postgres_user_password>'`
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
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault kv put secret/keycloak/helm admin_password='"$ADMIN_PASSWORD"' postgres_user_password='"$POSTGRES_USER_PASSWORD"''`

## Access
- URL: `https://keycloak.apps.k8s.enros.me`
- The admin credentials are configured via environment variables:
  - `KEYCLOAK_ADMIN=admin`
  - `KEYCLOAK_ADMIN_PASSWORD` from Secret `keycloak-helm` key `admin-password` (templated via `extraEnv`).

## Notes
- For production, consider external Postgres (`postgresql.enabled=false` and `externalDatabase.*` values) and HA settings.
- Keep Helm version pinned via `targetRevision` and rotate credentials in Vault as needed.
## Prepare External PostgreSQL
- Ensure the PostgreSQL app from this repo is synced and running.
- Values under `database.*` configure the external DB:
  - `vendor: postgres`
  - `hostname: postgresql-postgresql.postgresql.svc.cluster.local`
  - `database: keycloak`, `username: keycloak`
  - `existingSecret: keycloak-helm`, `existingSecretKey: postgres-user-password`
- Create DB and user (using Vault or K8s secrets for credentials):
  - Get admin password from Vault or from Secret `postgresql-helm` in namespace `postgresql`.
  - Execute in the primary pod:
    - `kubectl -n postgresql exec -it sts/postgresql-postgresql -- bash`
    - `psql -U postgres`
    - SQL:
      - `CREATE USER keycloak WITH PASSWORD '<strong_password>';`
      - `CREATE DATABASE keycloak OWNER keycloak TEMPLATE template0 ENCODING 'UTF8';`
      - `GRANT ALL PRIVILEGES ON DATABASE keycloak TO keycloak;`
  - Store `<strong_password>` in Vault at `secret/keycloak/helm` as `postgres_user_password` (ESO will sync to Secret `keycloak-helm`).

## Manual Verification
- Check ExternalSecret: `kubectl -n keycloak describe externalsecret keycloak-helm`
- Force reconcile: `kubectl -n keycloak annotate externalsecret keycloak-helm reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite`
- Confirm Secret and decode:
  - `kubectl -n keycloak get secret keycloak-helm -o jsonpath='{.data.admin-password}' | base64 -d; echo`
  - `kubectl -n keycloak get secret keycloak-helm -o jsonpath='{.data.postgres-user-password}' | base64 -d; echo`

## Troubleshooting
- Secret not found on first boot:
  - The ExternalSecret may materialize `keycloak-helm` after the pod starts. The mount will succeed after a restart.
  - Check: `kubectl -n keycloak get secret keycloak-helm -o yaml`
- External PostgreSQL is enabled by default in this setup; consider HA or a managed service for production.
- Image pull errors for Keycloak:
  - Inspect rendered images:
    - Keycloak: `kubectl -n keycloak get sts keycloak -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'`
  - Ensure Argo CD applied `keycloak/values.yml`. Force sync: `argocd app sync keycloak --prune --refresh`
- DB connection issues:
  - Verify service DNS: `postgresql-postgresql.postgresql.svc.cluster.local:5432`
  - Check credentials in Secret `keycloak-helm` key `postgres-user-password`.
  - Confirm DB and role exist: connect to Postgres primary and `\l` / `\du` in `psql`.
