# Authelia

Deploys Authelia via the official Helm chart, managed by Argo CD. Exposes HTTPS via Traefik with Let's Encrypt; secrets sourced from Vault via External Secrets.

## Structure

```
application.yml              # ArgoCD Application — chart + values.yml
values.yml                   # Helm values (ingress, secret file wiring, storage/notifier/auth backends)
kustomization.yml            # Includes namespace.yml and secrets.externalsecret.yml
secrets.externalsecret.yml   # ESO — creates Secret authelia-helm from Vault
namespace.yml                # authelia namespace
```

## Vault Setup

Seed credentials before first sync:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

# Generate strong secrets
export JWT_SECRET="$(openssl rand -hex 32)"
export SESSION_SECRET="$(openssl rand -hex 32)"
export STORAGE_ENCRYPTION_KEY="$(openssl rand -hex 32)"
export RESET_PASSWORD_JWT_HMAC_KEY="$(openssl rand -hex 32)"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/authelia/helm \
    jwt_secret='$JWT_SECRET' \
    session_secret='$SESSION_SECRET' \
    storage_encryption_key='$STORAGE_ENCRYPTION_KEY' \
    reset_password_jwt_hmac_key='$RESET_PASSWORD_JWT_HMAC_KEY'
"
```

Seed the users database (file backend):

```bash
# Option A — copy a local file
kubectl cp /path/to/users_database.yml vault/vault-0:/tmp/users_database.yml -c vault
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/authelia/users users_database.yml=@/tmp/users_database.yml
"

# Option B — write inline
kubectl exec -n vault vault-0 -c vault -- sh -c 'cat >/tmp/users_database.yml <<EOF
users:
  admin:
    displayname: "Authelia Admin"
    email: admin@example.com
    password: "$argon2id$v=19$m=65536,t=3,p=4$..."
    groups:
      - admins
EOF'
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/authelia/users users_database.yml=@/tmp/users_database.yml
"
```

### Vault Policy

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault policy write authelia - <<EOF
path \"secret/data/authelia/*\" {
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
    policies="'"$CURRENT"',authelia" ttl="1h"'
```

## Deploy

```bash
kubectl apply -f authelia/application.yml
```

## Verification

```bash
# Check ExternalSecret synced
kubectl -n authelia describe externalsecret authelia-helm

# Force reconcile
kubectl -n authelia annotate externalsecret authelia-helm \
  reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite

# Decode secret keys
kubectl -n authelia get secret authelia-helm -o jsonpath='{.data.jwt-secret}' | base64 -d; echo
kubectl -n authelia get secret authelia-helm -o jsonpath='{.data.session\.encryption\.key}' | base64 -d; echo
kubectl -n authelia get secret authelia-helm -o jsonpath='{.data.storage\.encryption\.key}' | base64 -d; echo
kubectl -n authelia get secret authelia-helm -o jsonpath='{.data.users_database\.yml}' | base64 -d | head -20
```

## Notes

- URL: `https://authelia.apps.k8s.enros.me`
- TLS managed by cert-manager via Traefik annotations.
- The `values.yml` mounts Vault-sourced secrets as files: file auth backend at `/secrets/users_database.yml`, local SQLite storage, filesystem notifier.
- Helm chart version is pinned in `application.yml` — bump with care and test first.

## Troubleshooting

- **Secret not syncing**: confirm Vault policy includes `secret/data/authelia/*` and the ESO role is updated.
- **Pod crash-looping**: verify all required keys exist in Vault (`jwt_secret`, `session_secret`, `storage_encryption_key`, `reset_password_jwt_hmac_key`, `users_database.yml`).
- **Login failing**: confirm `users_database.yml` at `secret/authelia/users` is valid YAML with expected user entries.
