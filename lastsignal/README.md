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