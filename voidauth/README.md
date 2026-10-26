# VoidAuth

Deploys VoidAuth (SSO provider) via Kustomize, managed by Argo CD. Ingress is exposed via Traefik with Let's Encrypt TLS; secrets are sourced from Vault via External Secrets. Uses the shared external PostgreSQL.

## Structure

```
application.yml              # ArgoCD Application — kustomize path
kustomization.yml            # Aggregates namespace, secrets, pvc, deployment, service, ingress
secrets.externalsecret.yml   # ESO — creates Secret voidauth-app from Vault
pvc.yml                      # Persistent config volume (mounted at /app/config)
deployment.yml               # VoidAuth Deployment with environment variables
service.yml                  # ClusterIP service on port 3000
ingress.yml                  # Traefik ingress with TLS
namespace.yml                # voidauth namespace
```

## Vault Setup

Seed credentials before first sync:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/voidauth/helm \
    storage_key='<random-32+-chars>' \
    db_user='voidauth' \
    db_password='<strong_password>' \
    db_name='voidauth'
"
```

Optional SMTP keys (only needed if you want email features enabled). These are stored in Vault, but are not wired into the Deployment by default.

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv patch secret/voidauth/helm \
    smtp_host='<smtp-host>' \
    smtp_user='<smtp-user>' \
    smtp_pass='<smtp-password>' \
    smtp_from='<from@example.com>' \
    smtp_port='587' \
    smtp_secure='false'
"
```

### Vault Policy

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault policy write voidauth - <<EOF
path \"secret/data/voidauth/*\" {
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
    policies="'"$CURRENT"',voidauth" ttl="1h"'
```

## Prepare External PostgreSQL

```bash
kubectl -n postgresql exec -it sts/postgresql-postgresql -- bash
psql -U postgres
```

```sql
CREATE USER voidauth WITH PASSWORD '<strong_password>';
CREATE DATABASE voidauth OWNER voidauth TEMPLATE template0 ENCODING 'UTF8';
GRANT ALL PRIVILEGES ON DATABASE voidauth TO voidauth;
```

Store `<strong_password>` in Vault at `secret/voidauth/helm` as `db_password`.

## Deploy

```bash
kubectl apply -f voidauth/application.yml
# or
argocd app sync voidauth --prune --refresh
```

## Verification

```bash
# ExternalSecret synced
kubectl -n voidauth describe externalsecret voidauth-app

# Force reconcile
kubectl -n voidauth annotate externalsecret voidauth-app \
  reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite

# VoidAuth pod and image
kubectl -n voidauth get pods -o wide
kubectl -n voidauth get deploy voidauth \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

# Ingress
kubectl -n voidauth get ingress voidauth -o wide

# First boot: initial admin credentials / reset link is printed to logs (only once for a fresh/empty DB)
kubectl -n voidauth logs deploy/voidauth --tail=200
```

## Admin Access

VoidAuth does not support setting an initial admin password via Kubernetes Secret or environment variable. The initial admin credentials/reset link is printed once on first boot; after that, use the CLI to generate a password reset link.

Generate a password reset link for the default admin user:

```bash
kubectl -n voidauth exec deploy/voidauth -- node ./dist/index.mjs generate password-reset auth_admin
```

If you are unsure of the username, list users (requires DB access inside the app):

```bash
kubectl -n voidauth exec deploy/voidauth -- node ./dist/index.mjs --help
```

## Notes

- URL: `https://auth.apps.k8s.enros.me`
- DB internal DNS: `postgresql.postgresql.svc:5432` (service `postgresql` in namespace `postgresql`)
- Config is persisted at `/app/config` via PVC `voidauth-config` to support branding/email template customization.

## Troubleshooting

- **DB connection errors**: validate `DB_HOST`, and confirm DB/user exist in the shared Postgres instance.
- **No admin reset link**: check first-boot logs; restarting the pod will re-run startup if the DB is empty.
- **Ingress 404/502**: confirm Traefik is installed and the `voidauth` service endpoints are ready.

## Traefik ForwardAuth integration

VoidAuth protects apps that have no native SSO through Traefik's `forwardAuth` middleware.

- Middleware: `traefik/voidauth.middleware.yml` (ns `traefik`, name `voidauth`) → calls `http://voidauth.voidauth.svc.cluster.local:3000/api/authz/forward-auth` and passes `Remote-User/Groups/Name/Email` to the app.
- Protected today: Traefik dashboard (`ingressRoute.dashboard.middlewares` in `traefik/values.yml`), trivy-ui, policy-reporter.
- Do NOT attach the middleware to the `voidauth` Ingress (login loop).
- Session cookie is shared because `auth.apps.k8s.enros.me` and the apps live under `apps.k8s.enros.me`.

### Protect another app

Ingress / Helm ingress annotations:

```yaml
traefik.ingress.kubernetes.io/router.middlewares: traefik-voidauth@kubernetescrd
```

IngressRoute (same-namespace rule applies, so use the cross-namespace form only if `providers.kubernetesCRD.allowCrossNamespace` is enabled):

```yaml
middlewares:
  - name: voidauth
    namespace: traefik
```

### Rollout order (avoids lockout)

1. VoidAuth UI (admin): create a group (e.g. `admins`), add your user, then under Proxy Auth add domains `trivy-ui.apps.k8s.enros.me/*`, `policy-reporter.apps.k8s.enros.me/*`, `traefik.apps.k8s.enros.me/*` restricted to that group.
2. Merge the PR; Argo syncs `traefik` (Middleware + dashboard), then trivy-ui / policy-reporter.
3. Verify. Rollback = revert the PR.

### Verification

```bash
kubectl -n traefik get middleware voidauth
curl -sI https://trivy-ui.apps.k8s.enros.me | head -3      # expect 302 to auth.apps.k8s.enros.me
curl -sI https://traefik.apps.k8s.enros.me/dashboard/ | head -3
```

Logged-in group member loads the app; a user outside the group gets 403.

### Troubleshooting

- Everything returns 200: set `ENABLE_DEBUG=true` on the Deployment and check logs for `proxyauth.action`. `reason=request_to_self_url` means wrong `X-Forwarded-Host`; switch the middleware `address` to the public `https://auth.apps.k8s.enros.me/api/authz/forward-auth`.
- 404 on a protected app: the middleware reference is wrong (must be `traefik-voidauth@kubernetescrd`) or the `traefik` app hasn't synced.
- Redirect loop: middleware attached to the VoidAuth ingress, or APP_URL not under the same parent domain as the app.
- 403 for your user: no Proxy Auth domain/group rule matches the host.
