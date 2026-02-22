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

## Access
- URL: `https://keycloak.apps.k8s.example.com`
- If using chart-generated admin secret instead, check the release notes; with `auth.existingSecret`, the admin password comes from Vault (`keycloak-helm` Secret).

## Notes
- For production, consider external Postgres (`postgresql.enabled=false` and `externalDatabase.*` values) and HA settings.
- Keep Helm version pinned via `targetRevision` and rotate credentials in Vault as needed.
