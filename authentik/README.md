# Authentik

Deploys Authentik (identity provider) via the official Helm chart, managed by
Argo CD. Ingress is exposed via Traefik with Let's Encrypt TLS; secrets are
sourced from Vault via External Secrets. Uses the shared external PostgreSQL
and the shared cluster Redis (`databases` namespace, also used by Authelia).

## Structure

```
application.yml                    # ArgoCD Application — chart + values.yml + kustomize path
values.yml                         # Helm values (existingSecret, global.env, ingress, media volume)
kustomization.yml                  # Aggregates namespace, secrets, media PVC
authentik-app.externalsecret.yml   # ESO — creates Secret authentik-app from Vault
media-pvc.yml                      # Persistent media volume (mounted at /media on server + worker)
namespace.yml                      # authentik namespace
```

## Vault Setup

Seed credentials before first sync. `secret_key` should be a long random
string (authentik uses it to sign sessions/cookies):

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/authentik/helm \
    secret_key='\$(openssl rand -base64 60 | tr -d '\n')' \
    db_password='<strong_password>'
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

Store `<strong_password>` in Vault at `secret/authentik/helm` as `db_password`
(must match what you created the Postgres user with above).

## Deploy

```bash
kubectl apply -f authentik/application.yml
# or
argocd app sync authentik --prune --refresh
```

## Verification

```bash
# ExternalSecret synced
kubectl -n authentik describe externalsecret authentik-app

# Force reconcile
kubectl -n authentik annotate externalsecret authentik-app \
  reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite

# Server and worker pods
kubectl -n authentik get pods -o wide

# Ingress
kubectl -n authentik get ingress -o wide

# Follow first-boot logs (initial admin bootstrap flow lives on /if/flow/initial-setup/)
kubectl -n authentik logs deploy/authentik-server --tail=200
kubectl -n authentik logs deploy/authentik-worker --tail=200
```

## Notes

- URL: `https://authentik.apps.k8s.enros.me`
- DB internal DNS: `postgresql.postgresql.svc.cluster.local:5432` (database
  `authentik`, user `authentik`)
- Redis internal DNS: `redis.databases.svc.cluster.local:6379` (shared,
  unauthenticated instance also used by Authelia — different logical Redis
  DBs, no conflict)
- The chart's own Secret template is bypassed entirely via
  `authentik.existingSecret.secretName: authentik-app` — the ESO-managed
  Secret supplies `AUTHENTIK_SECRET_KEY` and `AUTHENTIK_POSTGRESQL__PASSWORD`
  directly by literal env var name; non-secret connection settings
  (`AUTHENTIK_POSTGRESQL__HOST/NAME/USER/PORT`, `AUTHENTIK_REDIS__HOST/PORT`)
  are set as plain values in `global.env` in `values.yml`.
- Media (avatars, branding icons, flow backgrounds) persists on the
  `authentik-media` PVC mounted at `/media` on both server and worker — it's
  a `ReadWriteMany` claim on `kadalu.kadalu-pool-replica3` (the repo's first
  RWX PVC; the other kadalu-backed PVCs in this repo are all RWO for
  single-pod apps). If the storage class rejects RWX, fall back to giving
  server and worker each their own RWO PVC and accept that uploaded
  media/branding won't be visible from both pods.
- First admin setup: authentik has no environment-variable bootstrap
  password. Visit `/if/flow/initial-setup/` on a fresh database to create the
  initial `akadmin` account.

## Troubleshooting

- **DB connection errors**: validate `AUTHENTIK_POSTGRESQL__*` env vars on the
  server/worker deployments, and confirm the DB/user exist in the shared
  Postgres instance.
- **Worker not processing tasks / server can't reach Redis**: check
  `AUTHENTIK_REDIS__HOST` resolves and the shared Redis pod in `databases` is
  healthy (`kubectl -n databases get pods`).
- **CrashLoopBackOff citing a missing `AUTHENTIK_SECRET_KEY`**: the
  `authentik-app` ExternalSecret hasn't synced yet — check
  `kubectl -n authentik describe externalsecret authentik-app` and re-seed
  Vault if the `secret_key`/`db_password` fields are missing.
- **Ingress 404/502**: confirm Traefik is installed and the
  `authentik-server` service endpoints are ready.
