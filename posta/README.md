# Posta

Deploys [Posta](https://github.com/goposta/posta) — a self-hosted email delivery platform — via Kustomize, managed by Argo CD. Includes an in-namespace Redis deployment (Asynq queue backend). Ingress via Traefik with Let's Encrypt TLS; credentials sourced from Vault via External Secrets. Uses the shared external PostgreSQL.

## Structure

```
application.yml              # ArgoCD Application — kustomize path
kustomization.yml            # Aggregates namespace, Redis, secrets, deployment, service, ingress
secrets.externalsecret.yml   # ESO — creates Secret posta-helm from Vault
redis.yml                    # Redis 7 Deployment, PVC (1Gi), and Service
deployment.yml               # Posta app Deployment with embedded worker
service.yml                  # ClusterIP service on port 9000
ingress.yml                  # Traefik ingress with TLS
namespace.yml                # posta namespace
```

## Vault Setup

Seed credentials before first sync:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/posta/helm \
    jwt_secret='$(openssl rand -hex 32)' \
    admin_email='admin@example.com' \
    admin_password='<strong-password>' \
    db_url='host=postgresql-postgresql.postgresql.svc.cluster.local user=posta password=<db-password> dbname=posta port=5432 sslmode=disable'
"
```

### Vault Policy

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault policy write posta - <<EOF
path \"secret/data/posta/*\" {
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
    policies="'"$CURRENT"',posta" ttl="1h"'
```

## Prepare External PostgreSQL

```bash
kubectl -n postgresql exec -it sts/postgresql-postgresql -- bash
psql -U postgres
```

```sql
CREATE USER posta WITH PASSWORD '<db-password>';
CREATE DATABASE posta OWNER posta TEMPLATE template0 ENCODING 'UTF8';
GRANT ALL PRIVILEGES ON DATABASE posta TO posta;
```

## Deploy

```bash
kubectl apply -f posta/application.yml
# or
argocd app sync posta --prune --refresh
```

## Verification

```bash
# ExternalSecret synced
kubectl -n posta describe externalsecret posta-helm

# Force reconcile
kubectl -n posta annotate externalsecret posta-helm \
  reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite

# Redis
kubectl -n posta get pods -l app=redis
kubectl -n posta exec deploy/redis -- redis-cli ping

# Posta
kubectl -n posta get pods -l app=posta
kubectl -n posta logs deploy/posta

# Health endpoints
curl https://posta.apps.k8s.enros.me/api/v1/healthz
curl https://posta.apps.k8s.enros.me/api/v1/readyz
```

## Notes

- URL: `https://posta.apps.k8s.enros.me`
- API docs: `https://posta.apps.k8s.enros.me/docs`
- Redis internal DNS: `redis.posta.svc.cluster.local:6379`
- DB internal DNS: `postgresql-postgresql.postgresql.svc.cluster.local:5432`

## Troubleshooting

- **Secret not ready at first boot**: `kubectl rollout restart deploy/posta -n posta`.
- **Redis not reachable**: check PVC bound: `kubectl -n posta get pvc redis-data`.
- **readyz failing**: checks both DB and Redis — resolve those dependencies first.
