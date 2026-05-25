# Authelia

Deploys Authelia via the official Helm chart, managed by Argo CD. Exposes HTTPS via Traefik IngressRoute (CRD); secrets sourced from Vault via External Secrets. Storage backend: PostgreSQL.

## Structure

```
application.yml              # ArgoCD Application — chart + values.yml
values.yml                   # Helm values (storage, auth backends, Traefik CRD middleware)
kustomization.yml            # Includes namespace.yml and secrets.externalsecret.yml
secrets.externalsecret.yml   # ESO — creates Secret authelia-helm from Vault
namespace.yml                # authelia namespace
```

## Bootstrap (run once before first sync)

### 1. Generate secrets

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

export JWT_SECRET="$(openssl rand -hex 32)"
export SESSION_SECRET="$(openssl rand -hex 32)"
export STORAGE_ENCRYPTION_KEY="$(openssl rand -hex 32)"
export RESET_PASSWORD_JWT_HMAC_KEY="$(openssl rand -hex 32)"
export PG_PASSWORD="$(openssl rand -hex 16)"
```

### 2. Create PostgreSQL database and user

```bash
kubectl -n postgresql exec -it sts/postgresql -- bash
```

```sql
psql -U postgres
```

```sql
CREATE USER authelia WITH PASSWORD '<strong-password>';
CREATE DATABASE authelia OWNER authelia;
```

### 3. Seed Vault

```bash
# Core Authelia secrets
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/authelia/helm \
    jwt_secret='$JWT_SECRET' \
    session_secret='$SESSION_SECRET' \
    storage_encryption_key='$STORAGE_ENCRYPTION_KEY' \
    reset_password_jwt_hmac_key='$RESET_PASSWORD_JWT_HMAC_KEY'
"

# PostgreSQL password
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/authelia/postgres password='$PG_PASSWORD'
"
```

### 4. Seed users database (file auth backend)

```bash
# Generate an argon2id password hash
docker run authelia/authelia:latest authelia crypto hash generate argon2 --password 'yourpassword'

kubectl exec -n vault vault-0 -c vault -- sh -c 'cat >/tmp/users_database.yml <<EOF
users:
  admin:
    displayname: "Admin"
    email: admin@example.com
    password: "$argon2id$v=19$m=65536,t=3,p=4$..."   # replace with hash
    groups:
      - admins
      - users
EOF'
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/authelia/users users_database.yml=@/tmp/users_database.yml
"
```

### 5. Vault policy

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

### 6. Extend ESO role

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

## Using Authelia as a Traefik Middleware

The chart creates a `Middleware` CRD (`authelia-forwardauth`) in the `authelia` namespace via `traefikCRD.enabled: true`. Reference it from other apps:

**IngressRoute (Traefik CRD):**
```yaml
spec:
  routes:
    - middlewares:
        - name: authelia-forwardauth
          namespace: authelia
```

**Regular Ingress annotation:**
```yaml
traefik.ingress.kubernetes.io/router.middlewares: authelia-authelia-forwardauth@kubernetescrd
```

The middleware injects `Remote-User`, `Remote-Name`, `Remote-Email`, and `Remote-Groups` headers into upstream requests.

## Verification

```bash
# ExternalSecret synced (check all 5 keys including storage.postgres.password.txt)
kubectl -n authelia describe externalsecret authelia-helm

# Force reconcile if needed
kubectl -n authelia annotate externalsecret authelia-helm \
  reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite

# Pod status
kubectl -n authelia get pods

# Health endpoint
curl -sk https://authelia.apps.k8s.enros.me/api/health | jq

# Confirm Middleware CRD was created
kubectl -n authelia get middleware
```

## Notes

- URL: `https://authelia.apps.k8s.enros.me`
- Storage: PostgreSQL at `postgresql.postgresql.svc.cluster.local:5432`, database `authelia`
- Ingress: Traefik `IngressRoute` (CRD), TLS via cert-manager/Let's Encrypt
- ForwardAuth endpoint: `/api/authz/forward-auth` (Authelia 4.38+)
- Session cookie domain: `apps.k8s.enros.me`

## Troubleshooting

- **Secret not syncing**: confirm Vault policy covers `secret/data/authelia/*` and ESO role is updated
- **Pod crash on start**: all five keys must exist in `authelia-helm` secret (`jwt-secret`, `session.encryption.key`, `storage.encryption.key`, `users_database.yml`, `storage.postgres.password.txt`)
- **DB connection refused**: confirm `authelia` user + database exist in PostgreSQL before first sync
- **Middleware not found**: check `kubectl -n authelia get middleware`; if missing, verify `traefikCRD.enabled: true` in values and re-sync
