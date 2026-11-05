# Gitea

Self-hosted Git service, deployed from the official Helm chart (`https://dl.gitea.com/charts/`) to namespace `gitea`.
Uses the shared cluster PostgreSQL (`postgresql.postgresql.svc.cluster.local`, database `gitea`) and shared Redis
(`redis.redis.svc.cluster.local`, db `1` for cache/session/queue). The chart's bundled Postgres/Valkey are disabled.
Redis is non-persistent (see `redis/README.md`): queues and sessions are lost on a Redis restart.

## Structure

```
application.yml                # ArgoCD Application — gitea Helm chart + this repo's values
values.yml                     # Helm values (external PostgreSQL/Redis, bundled DBs disabled)
kustomization.yml              # Aggregates namespace, externalsecret, SSH IngressRouteTCP
namespace.yml                  # gitea namespace
gitea-app.externalsecret.yml   # ESO — creates Secret gitea-app from Vault
ssh.ingressroutetcp.yml        # Traefik IngressRouteTCP — ssh entrypoint (2222) → gitea-ssh
```

## Vault Setup

Seed credentials before first sync:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/gitea/helm \
    admin_username='gitea_admin' \
    admin_password='<strong_password>' \
    db_password='<db_password>'
"
```

### Vault Policy

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault policy write gitea - <<EOF
path \"secret/data/gitea/*\" {
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
    policies="'"$CURRENT"',gitea" ttl="1h"'
```

## Prepare External PostgreSQL

```bash
kubectl -n postgresql exec -it sts/postgresql -- bash
psql -U postgres
```

```sql
CREATE USER gitea WITH PASSWORD '<strong_password>';
CREATE DATABASE gitea OWNER gitea TEMPLATE template0 ENCODING 'UTF8';
GRANT ALL PRIVILEGES ON DATABASE gitea TO gitea;
```

Store `<strong_password>` in Vault at `secret/gitea/helm` as `db_password`.

## Deploy
```bash
kubectl apply -f gitea/application.yml
# or
argocd app sync gitea --prune --refresh
```

## Verification

```bash
kubectl -n gitea get externalsecret gitea-app
kubectl -n gitea rollout status deploy/gitea
kubectl -n gitea logs deploy/gitea | grep -i -E "error|database|redis"
```

## Notes

- URL: https://gitea.apps.k8s.example.com — SSH: Traefik `ssh` entrypoint (port 2222, `IngressRouteTCP` in `ssh.ingressroutetcp.yml`) → `gitea-ssh`. Clone with `git clone ssh://git@gitea.apps.k8s.example.com:2222/<owner>/<repo>.git`. Requires the Traefik LoadBalancer to expose port 2222 (`traefik/values.yml` `ports.ssh`).
- Redis is non-persistent: queues and sessions are lost on a Redis restart.

## Troubleshooting

- **DB connection errors**: confirm the `gitea` user/database exist and `db_password` in Vault matches.
- **Pod stuck on missing Secret**: check `kubectl -n gitea describe externalsecret gitea-app`; confirm `gitea` is in the ESO role policies.
- **SSH clone times out**: confirm Traefik exposes port 2222 (`ports.ssh` in `traefik/values.yml`) and the LoadBalancer allows it.
