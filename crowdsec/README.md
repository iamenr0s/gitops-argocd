# CrowdSec

Deploys CrowdSec (IDS/IPS) via the official Helm chart, managed by Argo CD. LAPI and agent connect to the shared external PostgreSQL for storage; credentials are sourced from Vault via External Secrets. No public ingress is exposed for the LAPI — there are no external bouncers/agents outside the cluster. The "webui" is a Grafana dashboard (auto-discovered by the `monitoring/` Grafana sidecar) rather than CrowdSec's deprecated bundled Metabase dashboard.

## Structure

```
application.yml                  # ArgoCD Application — chart + values.yml + kustomize
values.yml                       # Helm values (db_config, lapi envFrom/ingress/PV/metrics, agent acquisition)
kustomization.yml                # Aggregates namespace, secrets, dashboard ConfigMap
secrets.externalsecret.yml       # ESO — creates Secret crowdsec-db from Vault (sync-wave -1)
grafana-dashboard.configmap.yml  # Grafana dashboard ConfigMap (sidecar auto-discovered)
namespace.yml                    # crowdsec namespace
```

## Vault Setup

Seed credentials before first sync:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/crowdsec/helm \
    db_password='<strong_password>'
"
```

The DB user/name/host are not secret — they're inlined directly in `values.yml`'s `db_config` block, matching the chart's own example pattern.

### Vault Policy

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault policy write crowdsec - <<EOF
path \"secret/data/crowdsec/*\" {
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
    policies="'"$CURRENT"',crowdsec" ttl="1h"'
```

## Prepare External PostgreSQL

```bash
kubectl -n postgresql exec -it sts/postgresql -- bash
psql -U postgres
```

```sql
CREATE USER crowdsec WITH PASSWORD '<strong_password>';
CREATE DATABASE crowdsec OWNER crowdsec TEMPLATE template0 ENCODING 'UTF8';
GRANT ALL PRIVILEGES ON DATABASE crowdsec TO crowdsec;
```

Store `<strong_password>` in Vault at `secret/crowdsec/helm` as `db_password`.

## Deploy

```bash
kubectl apply -f crowdsec/application.yml
# or
argocd app sync crowdsec --prune --refresh
```

## Verification

```bash
# Pods, PVCs, services, ExternalSecret
kubectl -n crowdsec get pods,pvc,svc,externalsecret

# ExternalSecret synced
kubectl -n crowdsec describe externalsecret crowdsec-db

# Force reconcile
kubectl -n crowdsec annotate externalsecret crowdsec-db \
  reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite

# LAPI and agent status
kubectl -n crowdsec get deploy,daemonset -o wide

# DB connectivity + loaded collections (confirms db_config and COLLECTIONS env worked)
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli metrics
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli collections list

# ServiceMonitor present and scraped
kubectl -n crowdsec get servicemonitor
# then check the Prometheus targets page for crowdsec-lapi

# Grafana dashboard picked up by sidecar (no manual import needed)
kubectl -n monitoring logs -l app.kubernetes.io/name=grafana -c grafana-sc-dashboard | grep crowdsec
```

## Notes

- DB internal DNS: `postgresql.postgresql.svc.cluster.local:5432` (service `postgresql` in namespace `postgresql`)
- No public ingress for LAPI (`lapi.ingress.enabled: false`) — there are no external bouncers/agents outside the cluster, so LAPI stays ClusterIP-only.
- WebUI: CrowdSec's local dashboard (`cscli dashboard`, Metabase-based) is deprecated upstream. This deployment uses a Grafana dashboard ConfigMap (labeled `grafana_dashboard: "1"`) instead, auto-discovered by the existing `monitoring/` kube-prometheus-stack sidecar.
- Metrics are exposed on port `6060` and scraped via a `ServiceMonitor` (Prometheus Operator already runs cluster-wide per `monitoring/values.yml`).
- The agent ships with the `crowdsecurity/traefik` collection enabled and scrapes Traefik pod logs (`namespace: traefik`, `podName: traefik-*`) so the deployment detects something meaningful out of the box, since Traefik is the cluster's ingress controller.
- Persistent volumes (LAPI `data` and `config`) use the `kadalu.kadalu-pool-replica3` storage class, matching every other app's PVCs in this repo.

## Troubleshooting

- **DB connection errors**: confirm `crowdsec`/`crowdsec` DB+user exist in the shared Postgres instance and that `crowdsec-db` Secret contains the correct `DB_PASSWORD` (re-seed Vault and force ExternalSecret reconcile if not).
- **ExternalSecret not reconciling**: verify `external-secrets` controller is healthy and the `crowdsec` Vault policy is attached to the `external-secrets` Kubernetes auth role (`vault read auth/kubernetes/role/external-secrets`).
- **Agent not detecting Traefik logs**: confirm the Traefik pod naming matches `traefik-*` in the `traefik` namespace, and that the agent pod has read access (acquisition relies on the Kubernetes API, not a hostPath mount, for this source).
- **ServiceMonitor not scraped**: confirm the Prometheus Operator's `serviceMonitorNamespaceSelector` includes (or is empty/all-namespaces for) `crowdsec`.
- **Grafana dashboard not appearing**: check the sidecar logs (`grafana-sc-dashboard` container) for errors loading `crowdsec-grafana-dashboard`; confirm the ConfigMap label `grafana_dashboard: "1"` is present.
