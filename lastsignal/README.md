# LastSignal (Kustomize)

## Overview
- Deploys the LastSignal Ruby on Rails application via Kustomize, managed by Argo CD.
- Ingress exposed with Traefik and Let's Encrypt TLS; runtime credentials sourced from Vault via External Secrets.
- Uses the external PostgreSQL app from this repository; email delivery requires a reliable SMTP provider.

## Files
- `lastsignal/application.yml`: Argo CD Application pointing to `lastsignal/` Kustomize path.
- `lastsignal/kustomization.yml`: Aggregates namespace, secrets, deployment, service, and ingress.
- `lastsignal/secrets.externalsecret.yml`: ExternalSecret materializing `Secret lastsignal-helm` from Vault.
- `lastsignal/deployment.yml`: Rails app Deployment and environment variables.
- `lastsignal/service.yml`: ClusterIP service exposing port 3000.
- `lastsignal/ingress.yml`: Traefik ingress with TLS.
- `lastsignal/namespace.yml`: Namespace resource.

## Deploy
- `kubectl apply -f lastsignal/application.yml`
- Sync via Argo CD UI or `argocd app sync lastsignal --prune --refresh`

## Vault
- ClusterSecretStore: `vault-backend`
- Path: `secret/lastsignal/helm`
- Keys:
  - `rails_master_key`
  - `smtp_address`
  - `smtp_port`
  - `smtp_username`
  - `smtp_password`
  - `smtp_from`
  - `database_url` (e.g. `postgres://lastsignal:<strong_password>@postgresql-postgresql.postgresql.svc.cluster.local:5432/lastsignal`)

## Vault Setup (kubectl-only)
- Variables:
  - `export TOKEN='<vault_token>'`
  - `export RAILS_MASTER_KEY='<rails_master_key>'`
  - `export SMTP_ADDRESS='<smtp_host>'`
  - `export SMTP_PORT='<smtp_port>'`
  - `export SMTP_USERNAME='<smtp_user>'`
  - `export SMTP_PASSWORD='<smtp_password>'`
  - `export SMTP_FROM='<from_email>'`
  - `export DATABASE_URL='postgres://lastsignal:<strong_password>@postgresql-postgresql.postgresql.svc.cluster.local:5432/lastsignal'`
- Create read policy:
  ```bash
  cat > lastsignal-helm.hcl <<'EOF'
  path "secret/data/lastsignal/*" { capabilities = ["read"] }
  EOF
  kubectl cp lastsignal-helm.hcl vault/vault-0:/tmp/lastsignal-helm.hcl -c vault
  kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault policy write lastsignal-helm /tmp/lastsignal-helm.hcl'
  ```
- Bind role to ESO service account (append policy):
  ```bash
  kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault write auth/kubernetes/role/external-secrets bound_service_account_names="external-secrets" bound_service_account_namespaces="external-secrets" policies="harbor-admin,keycloak-helm,lastsignal-helm" ttl="1h"'
  ```
- Ensure KV v2 and seed secret:
  ```bash
  kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault secrets enable -path=secret kv-v2 || true'
  kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault kv put secret/lastsignal/helm rails_master_key='"$RAILS_MASTER_KEY"' smtp_address='"$SMTP_ADDRESS"' smtp_port='"$SMTP_PORT"' smtp_username='"$SMTP_USERNAME"' smtp_password='"$SMTP_PASSWORD"' smtp_from='"$SMTP_FROM"' database_url='"$DATABASE_URL"''
  ```

## Prepare External PostgreSQL
- Ensure the PostgreSQL app in this repo is synced and running.
- Create DB and user:
  - `kubectl -n postgresql exec -it sts/postgresql-postgresql -- bash`
  - `psql -U postgres`
  - SQL:
    - `CREATE USER lastsignal WITH PASSWORD '<strong_password>';`
    - `CREATE DATABASE lastsignal OWNER lastsignal TEMPLATE template0 ENCODING 'UTF8';`
    - `GRANT ALL PRIVILEGES ON DATABASE lastsignal TO lastsignal;`
- Store `<strong_password>` by composing `database_url` in Vault at `secret/lastsignal/helm`.

## Access
- URL: `https://lastsignal.apps.k8s.enros.me`
- Email delivery is mission‑critical—configure working SMTP credentials in Vault.

## Manual Verification
- ExternalSecret:
  - `kubectl -n lastsignal describe externalsecret lastsignal-helm`
  - Force reconcile: `kubectl -n lastsignal annotate externalsecret lastsignal-helm reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite`
  - Confirm Secret:
    - `kubectl -n lastsignal get secret lastsignal-helm -o jsonpath='{.data.rails-master-key}' | base64 -d; echo`
    - `kubectl -n lastsignal get secret lastsignal-helm -o jsonpath='{.data.database-url}' | base64 -d; echo`
- Deployment image:
  - `kubectl -n lastsignal get deploy lastsignal -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'`
- Service and Ingress:
  - `kubectl -n lastsignal get svc lastsignal`
  - `kubectl -n lastsignal get ingress lastsignal -o wide`
- TLS issuance:
  - Check certificate Secret `lastsignal-tls` and Traefik logs.

## Troubleshooting
- Secret not present at first boot: ExternalSecret may materialize after the pod starts; restart will mount values.
- Image pull issues:
  - Adjust `image` in `deployment.yml` to your own registry/tag if `ghcr.io/giovantenne/lastsignal` is unavailable.
  - For GHCR pulls, ensure proper authentication or logout stale tokens (`docker logout ghcr.io`).
- DB connection errors:
  - Verify DNS: `postgresql-postgresql.postgresql.svc.cluster.local:5432`
  - Validate `database_url` in Secret `lastsignal-helm`.
  - Connect to Postgres primary and inspect `\l` / `\du` via `psql`.
