# LastSignal

Deploys the LastSignal Ruby on Rails application via Kustomize, managed by Argo CD. Ingress exposed via Traefik with Let's Encrypt TLS; credentials sourced from Vault via External Secrets. Uses the shared external PostgreSQL.

## Structure

```
application.yml              # ArgoCD Application — kustomize path
kustomization.yml            # Aggregates namespace, secrets, deployment, service, ingress
secrets.externalsecret.yml   # ESO — creates Secret lastsignal-helm from Vault
deployment.yml               # Rails app Deployment with environment variables
service.yml                  # ClusterIP service on port 3000
ingress.yml                  # Traefik ingress with TLS
namespace.yml                # lastsignal namespace
```

## Vault Setup

Seed credentials before first sync:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/lastsignal/helm \
    rails_master_key='<rails-master-key>' \
    smtp_address='<smtp-host>' \
    smtp_port='587' \
    smtp_username='<smtp-user>' \
    smtp_password='<smtp-password>' \
    smtp_from='<from@example.com>' \
    database_url='postgres://lastsignal:<password>@postgresql.postgresql.svc.cluster.local:5432/lastsignal'
"
```

### Vault Policy

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault policy write lastsignal - <<EOF
path \"secret/data/lastsignal/*\" {
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
    policies="'"$CURRENT"',lastsignal" ttl="1h"'
```

## Prepare External PostgreSQL

```bash
kubectl -n postgresql exec -it sts/postgresql-postgresql -- bash
psql -U postgres
```

```sql
CREATE USER lastsignal WITH PASSWORD '<strong_password>';
CREATE DATABASE lastsignal OWNER lastsignal TEMPLATE template0 ENCODING 'UTF8';
GRANT ALL PRIVILEGES ON DATABASE lastsignal TO lastsignal;
```

Store `<strong_password>` by composing `database_url` in Vault at `secret/lastsignal/helm`.

## Deploy

```bash
kubectl apply -f lastsignal/application.yml
# or
argocd app sync lastsignal --prune --refresh
```

## Verification

```bash
# ExternalSecret synced
kubectl -n lastsignal describe externalsecret lastsignal-helm

# Force reconcile
kubectl -n lastsignal annotate externalsecret lastsignal-helm \
  reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite

# Decode credentials
kubectl -n lastsignal get secret lastsignal-helm \
  -o jsonpath='{.data.rails-master-key}' | base64 -d; echo
kubectl -n lastsignal get secret lastsignal-helm \
  -o jsonpath='{.data.database-url}' | base64 -d; echo

# Deployment image
kubectl -n lastsignal get deploy lastsignal \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

# Service and Ingress
kubectl -n lastsignal get svc lastsignal
kubectl -n lastsignal get ingress lastsignal -o wide
```

## Notes

- URL: `https://lastsignal.apps.k8s.enros.me`
- Email delivery is mission-critical — configure working SMTP credentials in Vault.
- DB internal DNS: `postgresql.postgresql.svc.cluster.local:5432`

## Troubleshooting

- **Secret not present at first boot**: ExternalSecret may materialize after pod starts; restart will mount the values.
- **Image pull issues**: adjust `image` in `deployment.yml` to your own registry/tag.
- **DB connection errors**: validate `database_url` in Secret `lastsignal-helm` and confirm DB/user exist.
