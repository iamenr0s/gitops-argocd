# CrowdSec

Deploys CrowdSec (IDS/IPS) via the official Helm chart, managed by Argo CD. LAPI and agent connect to the shared external PostgreSQL for storage; credentials are sourced from Vault via External Secrets. No public ingress is exposed for the LAPI — there are no external bouncers/agents outside the cluster. The "webui" is a Grafana dashboard (auto-discovered by the `monitoring/` Grafana sidecar) rather than CrowdSec's deprecated bundled Metabase dashboard.

## Structure

```
application.yml                  # ArgoCD Application — chart + values.yml + kustomize
values.yml                       # Helm values (db_config, lapi envFrom/ingress/PV/metrics, agent acquisition)
kustomization.yml                # Aggregates namespace, secrets, dashboard ConfigMap
secrets.externalsecret.yml       # ESO — creates Secret crowdsec-db from Vault (sync-wave -1)
enroll.externalsecret.yml        # ESO — creates Secret crowdsec-enroll from Vault (optional, sync-wave -1)
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

### Optional: CrowdSec Console enrollment

To send signals/alerts to CrowdSec's cloud console ([app.crowdsec.net](https://app.crowdsec.net/) → Security Engines → Enroll command → Kubernetes tab), seed an enrollment key as its own Vault property and let `enroll.externalsecret.yml` pick it up:

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/crowdsec/helm \
    enroll_key='<crowdsec_console_enroll_key>'
"
```

This is kept as a *separate* ExternalSecret (`crowdsec-enroll`, sync-wave `-1`) rather than added to `crowdsec-db`'s property list, so that an unseeded/missing `enroll_key` can never fail the sync of the critical `DB_PASSWORD`. `lapi.envFrom` references `crowdsec-enroll` with `optional: true`, so the LAPI pod starts fine whether or not the secret exists. When it does exist, the chart's entrypoint auto-runs `cscli console enroll` using `ENROLL_KEY` on startup. After deploying, accept the enrollment in the console UI.

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

# Console enrollment status (only meaningful if enroll_key was seeded)
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli console status

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
- **LAPI crashloops with `authenticate watcher ... API error: Forbidden`, or `cscli capi register` returns `http 403 Forbidden`**: the Central API (CAPI, `api.crowdsec.net`) is rate-limiting your egress IP. Free accounts are blocked for about 1 hour per IP after more than ~20 logins in 50 minutes, and a LAPI crashloop re-authenticates on every restart, so it keeps the ban alive ([CrowdSec docs](https://docs.crowdsec.net/u/troubleshooting/capi_403)). Database connectivity is not the problem if the logs show the DB connected. Recovery:
  1. Pause Argo CD self-heal and stop the loop so nothing contacts CAPI:

     ```bash
     kubectl -n argocd patch app crowdsec --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
     kubectl -n crowdsec scale deploy/crowdsec-lapi --replicas=0
     ```

  2. If the stored CAPI credentials are stale, delete `online_api_credentials.yaml` from the LAPI config PVC (find it with `kubectl -n crowdsec get pvc`) using a temporary pod that mounts the PVC at `/etc/crowdsec`. Without the file the LAPI starts with CAPI disabled (`Communication with CrowdSec Central API disabled from configuration file`); local detection and decisions still work, only the community blocklist is missing.
  3. Re-enable sync and start the LAPI:

     ```bash
     kubectl -n argocd patch app crowdsec --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
     kubectl -n crowdsec scale deploy/crowdsec-lapi --replicas=1
     ```

  4. Wait at least an hour (up to ~24 hours if it persists) with **no** CAPI calls; every retry can extend the ban. Then try once:

     ```bash
     kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli capi register
     kubectl -n crowdsec rollout restart deploy/crowdsec-lapi
     kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli capi status
     ```

  If it still returns 403, check for other CrowdSec engines sharing the same public IP, register from a different egress IP and copy the generated `online_api_credentials.yaml` into the config PVC, or ask CrowdSec support ([forum](https://discourse.crowdsec.net/)) with your public IP.
- **Checking CAPI and enrolling manually once the LAPI is Running**: check the CAPI state and only re-register if the status fails (mind the rate limit above), then restart so the LAPI loads new credentials:

  ```bash
  kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli capi status
  kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli capi register   # only if status fails
  kubectl -n crowdsec rollout restart deploy/crowdsec-lapi
  ```

  Then enroll in the CrowdSec Console by hand. Generate a fresh enrollment key first if the console shows the old one as used, then accept the enrollment in the console UI:

  ```bash
  kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli console enroll --overwrite --name homelab-cluster --tags k8s --tags homelab <key>
  ```

- **Log noise that is harmless**: `GeoLite2-City.mmdb` missing (GeoIP enrichment only, the file comes from hub data), `Error: no matches found` in the entrypoint (unmatched glob), and a new `Machine ... successfully added` on every LAPI start. Clean up stale machines occasionally with `cscli machines prune`.
- **ExternalSecret not reconciling**: verify `external-secrets` controller is healthy and the `crowdsec` Vault policy is attached to the `external-secrets` Kubernetes auth role (`vault read auth/kubernetes/role/external-secrets`).
- **Agent not detecting Traefik logs**: confirm the Traefik pod naming matches `traefik-*` in the `traefik` namespace, and that the agent pod has read access (acquisition relies on the Kubernetes API, not a hostPath mount, for this source).
- **ServiceMonitor not scraped**: confirm the Prometheus Operator's `serviceMonitorNamespaceSelector` includes (or is empty/all-namespaces for) `crowdsec`.
- **Grafana dashboard not appearing**: check the sidecar logs (`grafana-sc-dashboard` container) for errors loading `crowdsec-grafana-dashboard`; confirm the ConfigMap label `grafana_dashboard: "1"` is present.
