# Telegraf Operator

Deploys the InfluxData [telegraf-operator](https://github.com/influxdata/helm-charts/tree/master/charts/telegraf-operator) via Helm, managed by Argo CD. The operator watches Kubernetes pods and runs Telegraf as a sidecar to scrape metrics and forward them to InfluxDB.

Upstream: https://github.com/influxdata/telegraf

## Structure

```
application.yml   # Argo CD Application — chart telegraf-operator
values.yml        # Helm values (operator config + classes secret)
namespace.yml     # telegraf namespace
kustomization.yml # Aggregates namespace
```

## Configuration

`values.yml` ships with the upstream defaults, including a single `classes.infra` class that posts metrics to the local InfluxDB at `http://influxdb.influxdb:8086` with `env=ci` global tags.

Edit the `classes.data` block to point at your real InfluxDB or to add additional input/output plugins per class.

## Deploy

Commit and push — Argo CD will sync the app to namespace `telegraf`.

## Verification

```bash
# Operator
kubectl -n telegraf get deploy telegraf-operator

# Operator classes secret
kubectl -n telegraf get secret telegraf-operator-classes -o yaml

# Telegraf sidecars on annotated pods
kubectl get pods -A -o json | jq -r '.items[].spec.containers[].name' | grep -i telegraf | sort -u

# Force reconcile
argocd app sync telegraf --prune --refresh
```

## Notes

- Image: `quay.io/influxdb/telegraf-operator` (sidecar: `docker.io/library/telegraf:1.22`)
- Replicas: 3
- `certManager.enable: false` — if you flip this on, ensure `cert-manager` is deployed first.
- For hot reload, set `hotReload: true` (requires a Telegraf build that supports `--watch-config`).
