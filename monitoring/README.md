# Monitoring Stack (Argo CD App)

## Overview
- Deploys `kube-prometheus-stack` (Prometheus, Alertmanager, Grafana, exporters) via Helm.
- Uses Traefik for ingress and cert-manager for webhook certificates.
- Grafana admin credentials now provided via ExternalSecret backed by Vault.

## Files
- `application.yml`: Argo CD Application with Helm chart + local overlay.
- `values.yaml`: Helm values (ingress, operator settings, CRD job disabled, webhook patch disabled, cert-manager enabled).
- `kustomization.yml`: includes namespace and Grafana ExternalSecret.
- `namespace.yml`: creates the `monitoring` namespace.
- `grafana-auth.externalsecret.yml`: ExternalSecret that creates `grafana-secret`.

## Configuration Highlights
- Ingress hosts:
  - Prometheus: `prometheus.apps.k8s.enros.me`
  - Grafana: `grafana.apps.k8s.enros.me`
  - Alertmanager: `alertmanager.apps.k8s.enros.me`
- Grafana values expect secret `grafana-secret` with keys `admin-user` and `admin-password`.
- ExternalSecret maps Vault KV v2 `secret/grafana/admin` properties `admin_user` and `admin_password` to secret keys.

## Vault Setup (kubectl-only)
- Variables:
  - `export TOKEN='<vault_token>'`
  - `export GRAFANA_ADMIN_USER='admin'`
  - `export GRAFANA_ADMIN_PASSWORD='<strong_password>'`
- Create read policy:
  - `cat > grafana-read.hcl <<'EOF'`
  - `path "secret/data/grafana/*" { capabilities = ["read"] }`
  - `EOF`
  - `kubectl cp grafana-read.hcl vault/vault-0:/tmp/grafana-read.hcl -c vault`
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault policy write grafana-read /tmp/grafana-read.hcl'`
- Bind role to ESO service account (append policy):
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault write auth/kubernetes/role/external-secrets bound_service_account_names="external-secrets" bound_service_account_namespaces="external-secrets" policies="harbor-admin,grafana-read" ttl="1h"'`
- Ensure KV v2 and seed secret:
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault secrets enable -path=secret kv-v2 || true'`
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault kv put secret/grafana/admin admin_user='"$GRAFANA_ADMIN_USER"' admin_password='"$GRAFANA_ADMIN_PASSWORD"''`

## Deploy
- Commit and push; Argo CD will sync to namespace `monitoring`.

## Manual Verification
- `kubectl -n monitoring get pods`
- `kubectl -n monitoring get ingress`
- Trigger reconcile: `kubectl -n monitoring annotate externalsecret grafana-secret reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite`
- Check ExternalSecret: `kubectl -n monitoring describe externalsecret grafana-secret`
- Confirm secret and decode:
  - `kubectl -n monitoring get secret grafana-secret -o jsonpath='{.data.admin-user}' | base64 -d; echo`
  - `kubectl -n monitoring get secret grafana-secret -o jsonpath='{.data.admin-password}' | base64 -d; echo`

## Troubleshooting
- “could not get secret data from provider”: ensure Vault policy allows `secret/data/grafana/*` and ESO role includes `grafana-read`.
- Long sync on hooks: confirm cert-manager is installed and webhook patch jobs are disabled in values.
- CRD errors: ignore differences configured; manage CRDs via chart or dedicated app if needed.

