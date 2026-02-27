# Authelia (Helm)

## Overview
- Deploys Authelia via the official `authelia` Helm chart, managed by Argo CD.
- Exposes an HTTPS ingress through Traefik with Let's Encrypt.
- Sensitive keys are sourced from Vault and materialized with External Secrets Operator.

## Files
- `authelia/application.yml`: Argo CD Application pointing to the Authelia chart and `authelia/values.yml`.
- `authelia/values.yml`: Helm values (Ingress, secret file wiring, storage/notifier/auth backends).
- `authelia/kustomization.yml`: Includes `namespace.yml` and `secrets.externalsecret.yml`.
- `authelia/secrets.externalsecret.yml`: ExternalSecret that creates Secret `authelia-helm`.
- `authelia/namespace.yml`: Namespace manifest for `authelia`.

## Deploy
- `kubectl apply -f authelia/application.yml`
- Argo CD creates the namespace, reconciles secrets from Vault, and installs Authelia.

## Vault
- Path: `secret/authelia/helm`
- Keys:
  - `jwt_secret`
  - `session_secret` -> becomes file `session.encryption.key`
  - `storage_encryption_key` -> becomes file `storage.encryption.key`
  
- Path: `secret/authelia/users`
  - Keys:
    - `users_database.yml` (full YAML content for the file backend)

## Vault Setup (kubectl-only)
- Variables:
  - `TOKEN` from Vault (example retrieves from a secret if present):
    - `TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d 2>/dev/null || echo <your-admin-token>)"`
  - Generate strong secrets (or set your own):
    - `export JWT_SECRET="$(openssl rand -hex 32)"`
    - `export SESSION_SECRET="$(openssl rand -hex 32)"`
    - `export STORAGE_ENCRYPTION_KEY="$(openssl rand -hex 32)"`
- Create read policy for External Secrets (KV v2 paths use `/data/`):
  - `cat > authelia-helm.hcl <<'EOF'`
  - `path "secret/data/authelia/*" { capabilities = ["read"] }`
  - `EOF`
  - `kubectl cp authelia-helm.hcl vault/vault-0:/tmp/authelia-helm.hcl -c vault`
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault policy write authelia-helm /tmp/authelia-helm.hcl'`
- Append policy to ESO role (include other policies as needed):
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault write auth/kubernetes/role/external-secrets bound_service_account_names="external-secrets" bound_service_account_namespaces="external-secrets" policies="authelia-helm" ttl="1h"'`
- Ensure KV v2 and seed secrets:
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault secrets enable -path=secret kv-v2 || true'`
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault kv put secret/authelia/helm jwt_secret='"$JWT_SECRET"' session_secret='"$SESSION_SECRET"' storage_encryption_key='"$STORAGE_ENCRYPTION_KEY"''`
  - Seed users database file for the file backend:
    - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault kv put secret/authelia/users users_database.yml=@/tmp/users_database.yml'`

## Access
- URL: `https://authelia.apps.k8s.enros.me`
- TLS is managed by cert-manager via Traefik annotations.

## Manual Verification
- Check ExternalSecret: `kubectl -n authelia describe externalsecret authelia-helm`
- Force reconcile: `kubectl -n authelia annotate externalsecret authelia-helm reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite`
- Confirm Secret and decode:
  - `kubectl -n authelia get secret authelia-helm -o jsonpath='{.data.jwt-secret}' | base64 -d; echo`
  - `kubectl -n authelia get secret authelia-helm -o jsonpath='{.data.session\.encryption\.key}' | base64 -d; echo`
  - `kubectl -n authelia get secret authelia-helm -o jsonpath='{.data.storage\.encryption\.key}' | base64 -d; echo`
  - `kubectl -n authelia get secret authelia-helm -o jsonpath='{.data.users_database\.yml}' | base64 -d | head -n 20`

## Notes
- The Helm chart is version-pinned in `application.yml`. Bump with care and test in a non-production environment first.
- The `values.yml` mounts Vault-sourced secrets as files and configures:
  - File auth backend at `/secrets/users_database.yml`
  - Local storage (SQLite) and filesystem notifier
  - Ingress via Traefik with TLS
