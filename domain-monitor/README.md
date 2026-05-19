# domain-monitor

Self-hosted PHP domain expiration monitor with multi-channel alerting.
Upstream: https://github.com/Hosteroid/domain-monitor

## Architecture

- **App**: PHP/Apache container, port 80
- **Database**: MariaDB operator-managed instance (`mariadb.mariadb.svc.cluster.local:3306`)
  - Database: `domain-monitor`, User: `domain-monitor` (managed by CRDs in `mariadb/domain-monitor-db.yml`)
- **URL**: https://domain-monitor.apps.k8s.enros.me

## Configuration

The app is configured through two mechanisms working together:

- **Non-sensitive settings** → `configmap.yml` (`domain-monitor-config` ConfigMap), injected as env
  vars via `envFrom`.
- **Secrets** (`APP_ENCRYPTION_KEY`, `DB_PASSWORD`) → Vault → ESO → `domain-monitor-secrets` Secret,
  injected as env vars via `secretKeyRef`.

### Why `.env` is also mounted

Upstream's `public/index.php` explicitly throws if `/var/www/html/.env` is missing (see
`Dotenv::createImmutable(...)->load()`), even when all config is already present as env vars. To
satisfy this bootstrap check without baking config into the image, the `ExternalSecret` renders an
additional `.env` key via `spec.target.template`, and the Deployment mounts it at
`/var/www/html/.env` via `subPath`.

Env vars still take precedence (phpdotenv's immutable mode never overwrites pre-set env), so
`configmap.yml` remains the source of truth for non-sensitive settings — the `.env` file just
mirrors them to make the app happy. When adding or changing a setting, update **both** the
ConfigMap and the `.env` template in `secrets.externalsecret.yml`.

## Docker Image

The upstream repo does not publish a Docker image. Build and push it to Harbor before deploying:

```bash
git clone https://github.com/Hosteroid/domain-monitor.git
cd domain-monitor/domain-monitor-docker

docker build -t harbor.apps.k8s.enros.me/domain-monitor/domain-monitor:latest \
  -f .docker/Dockerfile .

docker push harbor.apps.k8s.enros.me/domain-monitor/domain-monitor:latest
```

Create the Harbor project `domain-monitor` first if it does not exist.

## Vault Setup

Seed secrets at `secret/domain-monitor/helm`:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=${TOKEN} vault kv put secret/domain-monitor/helm \
    app_encryption_key='$(openssl rand -base64 32)' \
    db_password='$(openssl rand -base64 24)'
"
```

### Vault Policy

Create a policy granting ESO read access:

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=${TOKEN} vault policy write domain-monitor - <<EOF
path \"secret/data/domain-monitor/*\" {
  capabilities = [\"read\"]
}
EOF
"
```

### Extend ESO Kubernetes Role

```bash
CURRENT=$(kubectl exec -n vault vault-0 -c vault -- sh -c \
  'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault read -field=policies auth/kubernetes/role/external-secrets' \
  | tr -d '[]' | tr ' ' ',')

kubectl exec -n vault vault-0 -c vault -- sh -c \
  'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault write auth/kubernetes/role/external-secrets \
    bound_service_account_names="external-secrets" \
    bound_service_account_namespaces="external-secrets" \
    policies="'"$CURRENT"',domain-monitor" ttl="1h"'
```

## First Deploy

1. Seed Vault secrets (above)
2. Build and push Docker image (above)
3. Apply ArgoCD Application:
   ```bash
   kubectl apply -f domain-monitor/application.yml
   ```
4. Wait for ExternalSecret to reconcile (~30s), then ArgoCD will sync all resources
5. Visit https://domain-monitor.apps.k8s.enros.me — the web installer will run on first access to create DB tables and the admin account

## Verification

```bash
# Check app pod is running
kubectl -n domain-monitor get pods

# Check ExternalSecret resolved (app namespace)
kubectl -n domain-monitor get externalsecret domain-monitor-secrets

# Check ExternalSecret resolved (mariadb namespace — for DB credentials)
kubectl -n mariadb get externalsecret domain-monitor-mariadb-creds

# Check operator CRDs provisioned
kubectl -n mariadb get database,user,grant domain-monitor

# Force ExternalSecret re-sync if needed
kubectl -n domain-monitor annotate externalsecret domain-monitor-secrets \
  reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite

# Tail app logs
kubectl -n domain-monitor logs -l app=domain-monitor -f

# Check MariaDB connectivity from app pod
kubectl -n domain-monitor exec -it deploy/domain-monitor -- \
  php -r "new PDO('mysql:host=mariadb.mariadb.svc.cluster.local;dbname=domain-monitor', 'domain-monitor', getenv('DB_PASSWORD'));"

# Confirm .env is mounted inside the pod
kubectl -n domain-monitor exec deploy/domain-monitor -- ls -la /var/www/html/.env
```

## Troubleshooting

### Pod in `CrashLoopBackOff` with liveness probe returning HTTP 500

Check `/var/www/html/logs/errors_YYYY-MM-DD.log` inside the pod. If you see

```
.env file not found! Please copy env.example.txt to .env and configure your settings.
```

the `.env` volume mount is missing or the `ExternalSecret` template failed to render the `.env`
key. Verify:

```bash
# The Secret should contain three keys: app-encryption-key, db-password, .env
kubectl -n domain-monitor get secret domain-monitor-secrets -o jsonpath='{.data}' \
  | python3 -c 'import json,sys; print(list(json.load(sys.stdin).keys()))'

# The deployment should mount .env at /var/www/html/.env via subPath
kubectl -n domain-monitor get deploy domain-monitor -o yaml \
  | grep -A 3 volumeMounts
```

If the `.env` key is missing from the Secret, force an ESO reconcile (command under Verification)
and check the ExternalSecret status for template errors.
