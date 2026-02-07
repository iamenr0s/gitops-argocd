# InfluxDB 2 (Argo CD App)

## Overview
- Deploys InfluxDB 2 via Helm with persistent storage and Traefik ingress.
- Admin credentials provided via sealed secret.

## Files
- `application.yml`: Argo CD Application for chart `influxdb2`.
- `values.yaml`: Helm values (storage, ingress, admin user).
- `kustomization.yml`: includes `influxdb-auth.sealed.yml`.
- `influxdb-auth.sealed.yml`: sealed secret containing admin password/token keys.

## Configuration Highlights
- Persistence enabled using storage class `kadalu.kadalu-pool-replica3`.
- Ingress enabled with TLS (`influxdb.apps.k8s.enros.me`) via Traefik and cert-manager annotations.
- Admin user references existing secret keys for password and token.

## Deploy
- Commit and push; Argo CD will sync the app to namespace `influxdb`.

## Manual Verification
- `kubectl -n influxdb get pods`
- `kubectl -n influxdb get svc,ing`
- Access `https://influxdb.apps.k8s.enros.me` and log in with credentials from the sealed secret.

## Troubleshooting
- Pod pending: verify storage class and PVC binding.
- 404/Ingress issues: confirm Traefik and certificate issuance.

