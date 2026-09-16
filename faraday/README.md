# Faraday

Deploys Faraday (vulnerability management platform) via raw manifests, managed
by ArgoCD — upstream has no official Helm chart. Ingress is exposed via
Traefik with Let's Encrypt TLS; secrets are sourced from Vault via External
Secrets. Uses the shared external PostgreSQL and the shared cluster Redis
(`databases` namespace, also used by Authelia and Authentik) as the Celery
broker/backend.

## Structure

```
application.yml                    # ArgoCD Application — kustomize path (no Helm chart upstream)
kustomization.yml                  # Aggregates all resources below
faraday-app.externalsecret.yml     # ESO — creates Secret faraday-app from Vault
server-ini.configmap.yml           # Custom /docker_server.ini (Celery broker/backend -> shared Redis)
data-pvc.yml                       # Persistent /home/faraday/.faraday volume (config, storage, logs, session)
deployment.yml                     # One pod: server + worker + beat containers, sharing the PVC
service.yml                        # ClusterIP :5985 -> server container
ingress.yml                        # faraday.apps.k8s.enros.me
namespace.yml                      # faraday namespace
```

## Vault Setup

Seed credentials before first sync:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/faraday/helm \
    db_password='<strong_password>' \
    admin_password='<strong_admin_password>'
"
```

### Vault Policy

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault policy write faraday - <<EOF
path \"secret/data/faraday/*\" {
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
    policies="'"$CURRENT"',faraday" ttl="1h"'
```

## Prepare External PostgreSQL

```bash
kubectl -n postgresql exec -it sts/postgresql-postgresql -- bash
psql -U postgres
```

```sql
CREATE USER faraday WITH PASSWORD '<strong_password>';
CREATE DATABASE faraday OWNER faraday TEMPLATE template0 ENCODING 'UTF8';
GRANT ALL PRIVILEGES ON DATABASE faraday TO faraday;
```

Store `<strong_password>` in Vault at `secret/faraday/helm` as `db_password`
(must match what you created the Postgres user with above).

## Deploy

```bash
kubectl apply -f faraday/application.yml
# or
argocd app sync faraday --prune --refresh
```

## Verification

```bash
# ExternalSecret synced
kubectl -n faraday describe externalsecret faraday-app

# Force reconcile
kubectl -n faraday annotate externalsecret faraday-app \
  reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite

# Pod (3/3 containers: server, worker, beat)
kubectl -n faraday get pods -o wide

# Ingress
kubectl -n faraday get ingress -o wide

# First-boot logs — admin password is printed here unless FARADAY_PASSWORD
# was seeded in Vault, in which case it's whatever you seeded
kubectl -n faraday logs deploy/faraday -c server --tail=200
kubectl -n faraday logs deploy/faraday -c worker --tail=100
kubectl -n faraday logs deploy/faraday -c beat --tail=100
```

## Notes

- URL: `https://faraday.apps.k8s.enros.me` (login: `faraday` / the
  `admin_password` seeded in Vault).
- DB internal DNS: `postgresql.postgresql.svc.cluster.local:5432` (database
  `faraday`, user `faraday`).
- Redis internal DNS: `redis.databases.svc.cluster.local:6379` (shared,
  unauthenticated instance also used by Authelia/Authentik — logical DB `4`,
  no conflict). Used only as the Celery broker/backend for the `worker`/`beat`
  containers; Faraday's session storage is left on its default (in-DB)
  backend since this runs a single server replica.
- All three containers (`server`, `worker`, `beat`) share one PVC at
  `/home/faraday/.faraday` in a single pod, mirroring upstream's
  docker-compose topology where the worker/beat containers depend on the
  server having already written `config/server.ini`. The `worker`/`beat`
  containers wait for that file to exist on the shared volume before
  starting, since the image's entrypoint skips all initialization when a
  command argument is passed to it.
- Upstream's baked-in `/docker_server.ini` hardcodes
  `celery_broker_url`/`celery_backend_url` to the bare hostname `redis`
  (assuming docker-compose's linked `redis` service) and is never rewritten
  at runtime by env vars — `server-ini.configmap.yml` overrides that file
  with the real shared-Redis URL before the server container's entrypoint
  copies it into place on first boot.
- First admin setup: username `faraday`, password from `FARADAY_PASSWORD`
  (seeded in Vault as `admin_password`); if that Secret key is ever missing
  on a fresh database, Faraday auto-generates one and prints it to the
  `server` container's first-boot logs instead.

## Troubleshooting

- **DB connection errors**: validate `PGSQL_*` env vars on all three
  containers, and confirm the DB/user exist in the shared Postgres instance.
- **Worker/beat stuck waiting, never reach Running**: check the `server`
  container's logs for migration/table-creation errors — `worker`/`beat`
  block on `config/server.ini` existing, which only happens once the server
  container completes its first-boot setup.
- **Celery tasks not processing / server can't reach Redis**: check
  `server-ini.configmap.yml`'s `celery_broker_url`/`celery_backend_url`
  resolve, and that the shared Redis pod in `databases` is healthy
  (`kubectl -n databases get pods`).
- **CrashLoopBackOff citing missing DB config**: the `faraday-app`
  ExternalSecret hasn't synced yet — check
  `kubectl -n faraday describe externalsecret faraday-app` and re-seed Vault
  if the `db_password`/`admin_password` fields are missing.
- **Ingress 404/502**: confirm Traefik is installed and the `faraday`
  service endpoints are ready.
