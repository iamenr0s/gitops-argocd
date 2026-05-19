# authentik

Deploys authentik via the official Helm chart, managed by Argo CD. Ingress exposed via Traefik with Let's Encrypt TLS; secrets sourced from Vault via External Secrets.

## Structure

```
application.yml              # ArgoCD Application — chart + values.yml
values.yml                   # Helm values (ingress, env, external PostgreSQL)
kustomization.yml            # Includes namespace.yml and secrets.externalsecret.yml
secrets.externalsecret.yml   # ESO — creates Secret authentik-helm from Vault
namespace.yml                # authentik namespace
```

## Vault Setup

Seed credentials before first sync:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/authentik/helm \
    secret_key='<50+-char-random-string>' \
    postgres_password='<db-user-password>'
"
```

### Vault Policy

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault policy write authentik - <<EOF
path \"secret/data/authentik/*\" {
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
    policies="'"$CURRENT"',authentik" ttl="1h"'
```

## Prepare External PostgreSQL

```bash
kubectl -n postgresql exec -it sts/postgresql-postgresql -- bash
psql -U postgres
```

```sql
CREATE USER authentik WITH PASSWORD '<strong_password>';
CREATE DATABASE authentik OWNER authentik TEMPLATE template0 ENCODING 'UTF8';
GRANT ALL PRIVILEGES ON DATABASE authentik TO authentik;
```

Store `<strong_password>` in Vault at `secret/authentik/helm` as `postgres_password`.

## Deploy

```bash
kubectl apply -f authentik/application.yml
```

## Verification

```bash
# Check ExternalSecret synced
kubectl -n authentik describe externalsecret authentik-helm

# Force reconcile
kubectl -n authentik annotate externalsecret authentik-helm \
  reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite

# Decode secret keys
kubectl -n authentik get secret authentik-helm -o jsonpath='{.data.secret_key}' | base64 -d; echo
kubectl -n authentik get secret authentik-helm -o jsonpath='{.data.password}' | base64 -d; echo
```

## Notes

- URL: `https://authentik.apps.k8s.enros.me`
- Initial setup: `https://authentik.apps.k8s.enros.me/if/flow/initial-setup/` (trailing slash required)
- Chart version pinned via `targetRevision` in `application.yml`.
- Uses external PostgreSQL (`postgresql.enabled: false`); service DNS: `postgresql-postgresql.postgresql.svc.cluster.local:5432`.

## Troubleshooting

- **404 on initial setup**: ensure URL includes trailing `/` and pods are healthy.
- **Secret not found on first boot**: re-sync app; deployment picks up the secret after reconcile.
- **DB connection issues**: check Postgres pod logs and credentials in Secret `authentik-helm`.
