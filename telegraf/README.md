# Telegraf Operator

Deploys the InfluxData [telegraf-operator](https://github.com/influxdata/helm-charts/tree/master/charts/telegraf-operator) via Helm, managed by Argo CD. The operator watches Kubernetes pods and runs Telegraf as a sidecar to scrape metrics and forward them to InfluxDB.

Upstream: https://github.com/influxdata/telegraf

## Structure

```
application.yml                       # Argo CD Application — chart telegraf-operator
values.yml                            # Helm values (operator config; classes.data intentionally empty)
telegraf-classes.externalsecret.yml   # Renders the telegraf-operator-classes secret from Vault
namespace.yml                         # telegraf namespace
kustomization.yml                     # Aggregates namespace + externalsecret
```

## Configuration

The operator injects a Telegraf sidecar into annotated pods, configured from a `classes` secret — one TOML block per class, selected via pod annotation (`--telegraf-default-class=infra` is the fallback). The chart can generate this secret itself from `values.yml`'s `classes.data`, but doing that would mean committing the InfluxDB token to git in plaintext, so `classes.data` is left empty here and `telegraf-classes.externalsecret.yml` provides the secret instead.

### Connecting to InfluxDB

The `infra` class's `[[outputs.influxdb_v2]]` block writes to the InfluxDB 2.x instance deployed by [`../influxdb`](../influxdb) at `http://influxdb.influxdb:8086` (org `influxdata`, bucket `default` — must match `influxdb/values.yml`'s `adminUser.organization`/`adminUser.bucket`). It uses the `outputs.influxdb_v2` plugin (token auth), not the legacy `outputs.influxdb` v1 plugin, since InfluxDB 2.x's v1-compatible write API doesn't accept the admin token as a username/password pair.

The token itself is never written to this repo. `telegraf-classes.externalsecret.yml` pulls it from Vault at `influxdb/admin` (property `admin_token`) — the same path the `influxdb` app already seeds for its own admin auth — and interpolates it into the TOML via `{{ .token }}` in the ExternalSecret's `template.data`. No new Vault path or ESO policy is needed: the shared `external-secrets` Kubernetes auth role already has read access to that path.

To point at a different InfluxDB instance/org/bucket, or add more classes, edit `telegraf-classes.externalsecret.yml`'s `template.data` directly (add more `secretKey`/`remoteRef` entries under `data:` for any additional Vault-sourced values).

## Deploy

Commit and push — Argo CD will sync the app to namespace `telegraf`.

## Verification

```bash
# Operator
kubectl -n telegraf get deploy telegraf-operator

# ExternalSecret synced from Vault
kubectl -n telegraf get externalsecret telegraf-operator-classes

# Operator classes secret (token is populated, not templated literal)
kubectl -n telegraf get secret telegraf-operator-classes -o jsonpath='{.data.infra}' | base64 -d

# Telegraf sidecars on annotated pods
kubectl get pods -A -o json | jq -r '.items[].spec.containers[].name' | grep -i telegraf | sort -u

# Confirm data is landing in InfluxDB
kubectl -n influxdb exec statefulset/influxdb-influxdb2 -- influx query \
  'from(bucket:"default") |> range(start:-5m) |> filter(fn:(r)=>r.type=="infra") |> limit(n:5)'

# Force reconcile
argocd app sync telegraf --prune --refresh
```

## Troubleshooting

- **`telegraf-operator-classes` secret missing / stale token**: force-reconcile the ExternalSecret:
  ```bash
  kubectl -n telegraf annotate externalsecret telegraf-operator-classes \
    force-sync="$(date +%s)" --overwrite
  ```
- **Sidecars can't write to InfluxDB (401/403)**: the token in Vault at `influxdb/admin`/`admin_token` may be stale relative to the InfluxDB instance (e.g. after a Vault rebuild) — reseed it, then force-reconcile as above.
- **`FailedMount: secret "telegraf-operator-tls" not found`** on first sync: expected, self-heals via kubelet's mount retry (the chart's cert-manager `Certificate` briefly races the `Deployment`).

## Notes

- Image: `quay.io/influxdb/telegraf-operator` (sidecar: `docker.io/library/telegraf:1.22`)
- Replicas: 3
- `certManager.enable: true` — the chart provisions its own in-namespace self-signed `Issuer`/`Certificate` for the mutating webhook (cert-manager must be running cluster-wide first).
- For hot reload, set `hotReload: true` (requires a Telegraf build that supports `--watch-config`).
