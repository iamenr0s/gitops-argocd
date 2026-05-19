# cert-manager

Installs cert-manager via Helm with CRDs, cluster issuers for Let's Encrypt (production and staging), and Cloudflare DNS-01 challenge. ACME email and Cloudflare API token are sourced from Vault via External Secrets.

## Structure

```
application.yml                               # ArgoCD Application — chart + local overlay
kustomization.yml                             # Includes issuer YAMLs and ExternalSecret resources
cluster-issuer-letsencrypt-production.yml     # ClusterIssuer for Let's Encrypt production
cluster-issuer-letsencrypt-staging.yml        # ClusterIssuer for Let's Encrypt staging
acme-contact.externalsecret.yml               # ESO — creates Secret acme-contact from Vault
cloudflare-api-token.externalsecret.yml       # ESO — creates Secret cloudflare-api-token from Vault
```

## Vault Setup

Seed credentials before first sync:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/cert-manager/acme \
    email='<you@example.com>'
"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/cert-manager/cloudflare \
    token='<cloudflare-api-token>'
"
```

### Vault Policy

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault policy write cert-manager - <<EOF
path \"secret/data/cert-manager/*\" {
  capabilities = [\"read\"]
}
EOF
"
```

### Extend ESO role

```bash
CURRENT=$(kubectl exec -n vault vault-0 -c vault -- sh -c \
  'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault read -field=policies auth/kubernetes/role/external-secrets' \
  | tr -d '[]' | tr ' ' ',')

kubectl exec -n vault vault-0 -c vault -- sh -c \
  'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault write auth/kubernetes/role/external-secrets \
    bound_service_account_names="external-secrets" \
    bound_service_account_namespaces="external-secrets" \
    policies="'"$CURRENT"',cert-manager" ttl="1h"'
```

## Deploy

Commit and push — Argo CD will sync the app and create the `cert-manager` namespace.

## Verification

```bash
# Operator pods
kubectl -n cert-manager get pods

# Cluster issuers
kubectl get clusterissuer

# Check ExternalSecrets synced
kubectl -n cert-manager describe externalsecret acme-contact
kubectl -n cert-manager describe externalsecret cloudflare-api-token

# Decode secrets
kubectl -n cert-manager get secret acme-contact -o jsonpath='{.data.email}' | base64 -d; echo
kubectl -n cert-manager get secret cloudflare-api-token -o jsonpath='{.data.token}' | base64 -d; echo
```

## Notes

- `installCRDs: true` is set in Helm values.
- Issuers use Secret `acme-contact` key `email` and Secret `cloudflare-api-token` key `token`.
- Issue a test Certificate or Ingress resource to confirm end-to-end TLS issuance.

## Troubleshooting

- **Secret not syncing**: ensure Vault policy covers `secret/data/cert-manager/*` and ESO role includes `cert-manager`.
- **Webhook failing**: ensure CRDs are installed and the webhook service is reachable.
- **ACME/DNS errors**: verify Cloudflare token has correct zone permissions.
