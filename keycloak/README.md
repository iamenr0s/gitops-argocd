# Keycloak

Deploys Keycloak using the codecentric `keycloakx` Helm chart, managed by Argo CD. Ingress exposed via Traefik with Let's Encrypt TLS. Admin password and DB credentials sourced from Vault via External Secrets; uses the shared external PostgreSQL.

## Structure

```
application.yml                  # ArgoCD Application — chart + values.yml
values.yml                       # Helm values (ingress, secrets, external database)
kustomization.yml                # Includes namespace.yml and admin-and-db.externalsecret.yml
admin-and-db.externalsecret.yml  # ESO — creates Secret keycloak-helm from Vault
namespace.yml                    # keycloak namespace
```

## Vault Setup

Seed credentials before first sync:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/keycloak/helm \
    admin_password='<admin-password>' \
    postgres_user_password='<db-user-password>'
"
```

### Vault Policy

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault policy write keycloak - <<EOF
path \"secret/data/keycloak/*\" {
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
    policies="'"$CURRENT"',keycloak" ttl="1h"'
```

## Prepare External PostgreSQL

```bash
kubectl -n postgresql exec -it sts/postgresql-postgresql -- bash
psql -U postgres
```

```sql
CREATE USER keycloak WITH PASSWORD '<strong_password>';
CREATE DATABASE keycloak OWNER keycloak TEMPLATE template0 ENCODING 'UTF8';
GRANT ALL PRIVILEGES ON DATABASE keycloak TO keycloak;
```

Store `<strong_password>` in Vault at `secret/keycloak/helm` as `postgres_user_password`.

## Deploy

```bash
kubectl apply -f keycloak/application.yml
```

## Verification

```bash
# ExternalSecret synced
kubectl -n keycloak describe externalsecret keycloak-helm

# Force reconcile
kubectl -n keycloak annotate externalsecret keycloak-helm \
  reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite

# Decode credentials
kubectl -n keycloak get secret keycloak-helm \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl -n keycloak get secret keycloak-helm \
  -o jsonpath='{.data.postgres-user-password}' | base64 -d; echo
```

## Notes

- URL: `https://keycloak.apps.k8s.enros.me`
- Admin login: `KEYCLOAK_ADMIN=admin`, password from Secret `keycloak-helm` key `admin-password`.
- DB: `postgresql-postgresql.postgresql.svc.cluster.local:5432`, database `keycloak`, user `keycloak`.

## Troubleshooting

- **Secret not found on first boot**: ExternalSecret may materialize after pod starts; restart will mount the secret.
- **Image pull errors**: force sync: `argocd app sync keycloak --prune --refresh`.
- **DB connection issues**: verify service DNS `postgresql-postgresql.postgresql.svc.cluster.local:5432` and check `\l` / `\du` in `psql`.
