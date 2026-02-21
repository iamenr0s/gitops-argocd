# Cert-Manager (Argo CD App)

## Overview
- Installs Cert-Manager via Helm with CRDs.
- Adds cluster issuers; ACME contact and Cloudflare token now provided via ExternalSecrets backed by Vault.

## Files
- `application.yml`: Argo CD Application pointing to `charts.jetstack.io` and local overlay.
- `kustomization.yml`: includes issuer and ExternalSecret resources.
- `cluster-issuer-letsencrypt-production.yml`, `cluster-issuer-letsencrypt-staging.yml`: ClusterIssuer definitions.
- `acme-contact.externalsecret.yml`: ExternalSecret for ACME email.
- `cloudflare-api-token.externalsecret.yml`: ExternalSecret for Cloudflare API token.

## Configuration Highlights
- `installCRDs: true` is set in Helm values to install required CRDs.
- Issuers reference secrets:
  - ACME email: secret `acme-contact` key `email` (annotations on issuer)
  - Cloudflare DNS: secret `cloudflare-api-token` key `token`
- ExternalSecrets map Vault KV v2 paths:
  - `secret/cert-manager/acme` property `email` → `acme-contact: email`
  - `secret/cert-manager/cloudflare` property `token` → `cloudflare-api-token: token`

## Vault Setup (kubectl-only)
- Variables:
  - `export TOKEN='<vault_token>'`
  - `export ACME_EMAIL='<you@example.com>'`
  - `export CF_TOKEN='<cloudflare_api_token>'`
- Create read policy:
  - `cat > cert-manager-read.hcl <<'EOF'`
  - `path "secret/data/cert-manager/*" { capabilities = ["read"] }`
  - `EOF`
  - `kubectl cp cert-manager-read.hcl vault/vault-0:/tmp/cert-manager-read.hcl -c vault`
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault policy write cert-manager-read /tmp/cert-manager-read.hcl'`
- Bind role to ESO service account (append policy):
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault write auth/kubernetes/role/external-secrets bound_service_account_names="external-secrets" bound_service_account_namespaces="external-secrets" policies="harbor-admin,cert-manager-read" ttl="1h"'`
- Ensure KV v2 and seed secrets:
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault secrets enable -path=secret kv-v2 || true'`
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault kv put secret/cert-manager/acme email='"$ACME_EMAIL"''`
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault kv put secret/cert-manager/cloudflare token='"$CF_TOKEN"''`

## Deploy
- Commit and push; Argo CD will sync the app and create the `cert-manager` namespace.

## Manual Verification
- `kubectl -n cert-manager get pods`
- `kubectl get clusterissuer`
- Check ExternalSecret statuses:
  - `kubectl -n cert-manager describe externalsecret acme-contact`
  - `kubectl -n cert-manager describe externalsecret cloudflare-api-token`
- Confirm secrets:
  - `kubectl -n cert-manager get secret acme-contact -o jsonpath='{.data.email}' | base64 -d; echo`
  - `kubectl -n cert-manager get secret cloudflare-api-token -o jsonpath='{.data.token}' | base64 -d; echo`
- Issue a test certificate with an Ingress or Certificate resource and watch it become `Ready`.

## Troubleshooting
- “could not get secret data from provider”: ensure Vault policy allows `secret/data/cert-manager/*` and ESO role includes `cert-manager-read`.
- Webhook failing: ensure CRDs installed and webhook service reachable.
- ACME/DNS errors: check provider token (Cloudflare) and domain/zone configuration.

