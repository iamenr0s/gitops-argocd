# Telegraf Operator

Deploys the InfluxData [telegraf-operator](https://github.com/influxdata/helm-charts/tree/master/charts/telegraf-operator) via Helm, managed by Argo CD. The operator watches Kubernetes pods and runs Telegraf as a sidecar to scrape metrics and forward them to InfluxDB.

Upstream: https://github.com/influxdata/telegraf

## Structure

```
application.yml                       # Argo CD Application — chart telegraf-operator
values.yml                            # Helm values (operator config; classes.data intentionally empty)
telegraf-classes.externalsecret.yml   # Renders the telegraf-operator-classes secret from Vault
x509-cert-check.deployment.yml        # Sidecar-only pod that runs the inputs.x509_cert check
namespace.yml                         # telegraf namespace
kustomization.yml                     # Aggregates namespace + externalsecret + deployment
```

## Configuration

The operator injects a Telegraf sidecar into annotated pods, configured from a `classes` secret — one TOML block per class, selected via pod annotation (`--telegraf-default-class=infra` is the fallback). The chart can generate this secret itself from `values.yml`'s `classes.data`, but doing that would mean committing the InfluxDB token to git in plaintext, so `classes.data` is left empty here and `telegraf-classes.externalsecret.yml` provides the secret instead.

### Connecting to InfluxDB

The `infra` class's `[[outputs.influxdb_v2]]` block writes to the InfluxDB 2.x instance deployed by [`../influxdb`](../influxdb) at `http://influxdb.influxdb:8086` (org `influxdata`, bucket `default` — must match `influxdb/values.yml`'s `adminUser.organization`/`adminUser.bucket`). It uses the `outputs.influxdb_v2` plugin (token auth), not the legacy `outputs.influxdb` v1 plugin, since InfluxDB 2.x's v1-compatible write API doesn't accept the admin token as a username/password pair.

The token itself is never written to this repo. `telegraf-classes.externalsecret.yml` pulls it from Vault at `influxdb/admin` (property `admin_token`) — the same path the `influxdb` app already seeds for its own admin auth — and interpolates it into the TOML via `{{ .token }}` in the ExternalSecret's `template.data`. No new Vault path or ESO policy is needed: the shared `external-secrets` Kubernetes auth role already has read access to that path.

To point at a different InfluxDB instance/org/bucket, or add more classes, edit `telegraf-classes.externalsecret.yml`'s `template.data` directly (add more `secretKey`/`remoteRef` entries under `data:` for any additional Vault-sourced values).

### SSL certificate expiry checks

`x509-cert-check.deployment.yml` is a minimal `pause`-container Deployment whose only purpose is to host a Telegraf sidecar — it never talks to any of the monitored URLs itself. Its pod annotation (`telegraf.influxdata.com/class: "x509-cert-check"`) selects a dedicated class, defined in `telegraf-classes.externalsecret.yml` alongside `infra`, that runs the [`inputs.x509_cert`](https://github.com/influxdata/telegraf/tree/master/plugins/inputs/x509_cert) plugin and writes to InfluxDB (`type = "x509-cert-check"` tag).

The list of URLs to check is never written to this repo. It's rendered directly into the class TOML server-side, the same way the `infra` class's InfluxDB `token` is: `telegraf-classes.externalsecret.yml`'s `data:` pulls it from Vault (`telegraf/x509-cert`, property `urls`) as `cert_urls`, and `template.data`'s `x509-cert-check` block interpolates it via `{{ .cert_urls }}` into `sources = [{{ .cert_urls }}]`.

This has to happen server-side in the ExternalSecret, not via the pod-level `telegraf.influxdata.com/inputs` + `env-secretkeyref` annotations (Telegraf's built-in `$VAR`-in-config mechanism, used elsewhere for `$HOSTNAME`/`$NODENAME`) — the operator statically validates the merged class+inputs TOML as plain text *before* Telegraf's own env-var substitution ever runs. An unquoted placeholder like `sources = [$CERT_URLS]` isn't valid TOML on its own, so that validation fails and the operator silently skips sidecar injection for the pod (`failurePolicy: Ignore` — no event, no error, just a pod stuck at 1/1 with only the `pause` container). `$HOSTNAME`/`$NODENAME` work today only because they sit *inside* an already-valid quoted string (`hostname = "$HOSTNAME"`); that trick doesn't extend to array values like `sources`. Templating server-side via ESO sidesteps the problem entirely: the rendered class is already complete, valid TOML with real URLs baked in — nothing left for the sidecar to substitute at runtime.

The Vault value must be the *inner content* of the TOML array — comma-separated, double-quoted, including the port — for example:

```
"https://example.com:443", "https://internal.home.enros.me:443"
```

To add or remove URLs, update that Vault value and force-reconcile `telegraf-operator-classes` (see Troubleshooting), then delete the `x509-cert-check` pod so the operator re-injects the sidecar with the refreshed class (the mutating webhook only fires on pod `CREATE`, not in-place updates).

## Vault Setup

No seeding needed here — `telegraf-classes.externalsecret.yml` reads the token from the path [`influxdb`](../influxdb) already seeds (`secret/influxdb/admin`, property `admin_token`), and the `external-secrets` Kubernetes auth role already carries the `influxdb` policy that grants read access to it:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault read -field=policies auth/kubernetes/role/external-secrets
"
# expect: [... influxdb ...]
```

If `influxdb` is missing from that list (e.g. after a Vault rebuild), follow [`../influxdb`](../influxdb)'s Vault Setup section to seed `secret/influxdb/admin` and extend the ESO role — that unblocks both apps at once, since they share the same Vault path.

The SSL cert check URL list lives at a new path, `secret/telegraf/x509-cert`, so it needs its own policy. Create it and extend the ESO role for the current-policies-first pattern), then seed the URL list:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

# 1. Create the read-only policy for this app's own Vault path
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN vault policy write telegraf - <<'EOF'
path \"secret/data/telegraf/*\" {
  capabilities = [\"read\"]
}
EOF
"

# 2. Extend the ESO role with the new policy (preserving existing ones)
CURRENT=$(kubectl exec -n vault vault-0 -c vault -- sh -c \
  'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault read -field=policies auth/kubernetes/role/external-secrets' \
  | tr -d '[]' | tr ' ' ',')
kubectl exec -n vault vault-0 -c vault -- sh -c \
  'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault write auth/kubernetes/role/external-secrets \
    bound_service_account_names="external-secrets" \
    bound_service_account_namespaces="external-secrets" \
    policies="'"$CURRENT"',telegraf" ttl="1h"'

# 3. Seed the URL list (comma-separated, double-quoted, with ports — the inner content of a TOML array)
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/telegraf/x509-cert urls='\"https://example.com:443\", \"https://internal.home.enros.me:443\"'
"
```

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

# Confirm data is landing in InfluxDB (needs -o <org> and -t <token>; the container has no CLI config)
INFLUX_TOKEN="$(kubectl -n influxdb get secret influxdb-influxdb2-auth -o jsonpath='{.data.admin-token}' | base64 -d)"
kubectl -n influxdb exec statefulset/influxdb-influxdb2 -- influx query \
  'from(bucket:"default") |> range(start:-5m) |> filter(fn:(r)=>r.type=="infra") |> limit(n:5)' \
  -o influxdata -t "$INFLUX_TOKEN"

# SSL cert check: class rendered with real URLs (not empty/templated literal)
kubectl -n telegraf get secret telegraf-operator-classes -o jsonpath='{.data.x509-cert-check}' | base64 -d

# Sidecar injected (2/2 containers: pause + telegraf) and running
kubectl -n telegraf get pods -l app=x509-cert-check
kubectl -n telegraf logs deploy/x509-cert-check -c telegraf --tail=50

# Confirm cert expiry data is landing in InfluxDB
kubectl -n influxdb exec statefulset/influxdb-influxdb2 -- influx query \
  'from(bucket:"default") |> range(start:-15m) |> filter(fn:(r)=>r._measurement=="x509_cert") |> limit(n:20)' \
  -o influxdata -t "$(kubectl -n influxdb get secret influxdb-influxdb2-auth -o jsonpath='{.data.admin-token}' | base64 -d)"

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
- **`x509-cert-check` pod has only the `pause` container, never gets a `telegraf` sidecar**: the operator's `failurePolicy: Ignore` webhook silently skips injection on any class TOML parse error — it does **not** show up as a pod event. Check the operator's own logs for the actual cause:
  ```bash
  kubectl -n telegraf logs -l app.kubernetes.io/name=telegraf-operator --since=10m | grep -i "x509-cert-check\|parse error"
  ```
  The most likely cause is a malformed `secret/telegraf/x509-cert`'s `urls` value (see [SSL certificate expiry checks](#ssl-certificate-expiry-checks) for the required format) rendering invalid TOML into the `x509-cert-check` class. After fixing the Vault value and force-reconciling `telegraf-operator-classes`, delete the pod so the operator re-evaluates it on recreation (in-place `UPDATE`s aren't mutated):
  ```bash
  kubectl -n telegraf delete pod -l app=x509-cert-check
  ```

## Notes

- Image: `quay.io/influxdb/telegraf-operator` (sidecar: `docker.io/library/telegraf:1.22`)
- Replicas: 3
- `certManager.enable: true` — the chart provisions its own in-namespace self-signed `Issuer`/`Certificate` for the mutating webhook (cert-manager must be running cluster-wide first).
- For hot reload, set `hotReload: true` (requires a Telegraf build that supports `--watch-config`).
