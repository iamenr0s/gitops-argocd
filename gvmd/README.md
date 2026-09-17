# gvmd

Deploys `gvmd` (Greenbone Vulnerability Manager) + `ospd-openvas` + a dedicated
`pg-gvm` Postgres via raw manifests — upstream has no official Helm chart.
Exists to give [Faraday](../faraday) a GMP scan runner: Faraday's
OpenVAS/GVM integration needs `host`/`port`/`gvm_user`/`gvm_passwd`, which is
GMP-protocol auth against `gvmd` — not the `openvasd` REST API that
[`openvas-scanner`](../openvas-scanner) already runs. `gvmd` talks to the scan
engine over OSP to `ospd-openvas` (a separate component from `openvasd`), so
this is a new app, not a config change to the existing one. No public
ingress — ClusterIP-only, same posture as `openvas-scanner`.

## Structure

```
application.yml                # ArgoCD Application — kustomize path (no Helm chart upstream)
kustomization.yml               # Aggregates all resources below
namespace.yml                   # gvmd namespace
storage.externalsecret.yml      # ESO — creates Secret gvmd-app (Postgres password, GMP user/password) from Vault
postgres-pvc.yml                # gvmd-postgres-data PVC — pg-gvm's /var/lib/postgresql
gvmd-data-pvc.yml               # gvmd-data PVC — gvmd's /var/lib/gvm (certs, tickets, report exports)
deployment.yml                  # One pod: feed initContainers + pg-gvm/redis/ospd-openvas/gvmd containers
service.yml                     # ClusterIP :9390 -> gvmd GMP
```

## Architecture notes

- **Why a new Postgres instead of the shared `postgresql` app**: gvmd's
  schema depends on the `pg-gvm` Postgres extension — a compiled C library
  (host/ical SQL functions) built from `greenbone/pg-gvm`. It has to be
  physically present in the server's `$libdir`; there's no config flag to add
  it to the shared cluster `postgresql` app's stock `bitnami/postgresql`
  image, and forking that image would touch infra every other app using it
  (faraday, etc.) depends on. Instead, `pg-gvm` runs as a **sidecar inside
  this pod** — exactly upstream's own compose topology (gvmd and pg-gvm share
  a unix socket over `psql-socket`, an emptyDir), not a separate app-like
  Postgres Deployment/Service. `pg-gvm`'s own startup script
  (`start-postgresql.sh`) self-initializes the `gvmd` role/database and the
  `uuid-ossp`/`pgcrypto`/`pg-gvm` extensions from `POSTGRES_PASSWORD` on first
  boot.
- **gvmd ↔ ospd-openvas**: OSP over a shared unix socket (`ospd-socket`,
  emptyDir, mounted at `/run/ospd` in both containers) — never touches
  `openvasd`'s REST API.
- **Feed volumes** (`vt-data`, `notus-data`, `gpg-data`, `scap-data`,
  `cert-data`, `data-objects`) are populated by initContainers using
  Greenbone's official feed images, same pattern as
  `openvas-scanner/deployment.yml`: they re-run on every pod (re)start and
  are `emptyDir`, not PVCs — this data is fully rebuildable, and kadalu
  replication of multi-GB feed content adds slow, pointless overhead for zero
  durability benefit (see `openvas-scanner/README.md` "Architecture notes"
  for the full rationale). `ospd-openvas` and `gvmd` need their own copies of
  this content — pods can't share another pod's `emptyDir`, and coupling this
  app's pod restarts to `openvas-scanner`'s PVC would create an unwanted
  cross-app sync dependency. Trade-off: feed content is downloaded twice
  across the cluster (once here, once in `openvas-scanner`) on a cold start.
- **Table-driven LSC reuse**: `configure-openvas`'s init step points
  `openvasd_server` at `openvasd.openvas-scanner.svc.cluster.local:3000` (the
  already-running `openvas-scanner` deployment) instead of running a third
  in-cluster scan engine just for local security checks.
- **Redis**: same `redis:7-alpine` unix-socket-only config as
  `openvas-scanner/deployment.yml`'s sidecar — its own instance, since
  sockets are pod-scoped and can't be shared across pods.
- **GMP over TCP**: `gvmd`'s image defaults `GVMD_ARGS` to
  `-f --listen-mode=666` (unix-socket-only). This deployment overrides it to
  add `--listen=0.0.0.0 --port=9390`, exposing GMP over TCP so Faraday can
  reach it. These are gvmd's documented GMP-TCP flags but weren't verified
  against a running instance before this was written — if wrong/renamed for
  this gvmd version, `gvmd --help` inside the pod shows the current flag
  names; fix is a one-line `GVMD_ARGS` edit in `deployment.yml`.
- **Faraday's GMP user**: `USER`/`PASSWORD` env vars on the `gvmd` container
  make its startup script (`gvmd --create-user=$USER --password=$PASSWORD`)
  create exactly the account Faraday authenticates as. This account is always
  full-Admin — the bootstrap script has no lesser-role option. A more scoped
  GMP role can be added later with a second
  `gvmd --create-user --role=<role-uuid>` if desired; not required for the
  integration to work.
- **`ospd-openvas` capabilities**: needs `NET_ADMIN`/`NET_RAW` (same as
  `openvasd` today) plus `seccompProfile: Unconfined`, mirroring upstream
  compose's `seccomp=unconfined` for raw packet capture / promiscuous-mode
  Boreas alive detection.

## Vault Setup

Seed credentials before first sync:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/gvmd/helm \
    postgres_password='<strong_password>' \
    gvm_user='faraday' \
    gvm_password='<strong_password>'
"
```

### Vault Policy

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault policy write gvmd - <<EOF
path \"secret/data/gvmd/*\" {
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
    policies="'"$CURRENT"',gvmd" ttl="1h"'
```

## Deploy

```bash
kubectl apply -f gvmd/application.yml
# or
argocd app sync gvmd --prune --refresh
```

First sync pulls the full VT/SCAP/CERT feeds (multi-GB) via the feed
initContainers — the pod stays `Init:x/9` for a while on first boot, same as
`openvas-scanner`'s `vt-feed` startup behavior.

## Verification

```bash
# ExternalSecret synced
kubectl -n gvmd describe externalsecret gvmd-app

# Pod (initContainers complete, then pg-gvm + redis + ospd-openvas + gvmd all Running)
kubectl -n gvmd get pods -o wide

# gvmd connected to Postgres and to the ospd-openvas socket
kubectl -n gvmd logs deploy/gvmd -c gvmd

# Confirm the Faraday GMP user was created
kubectl -n gvmd exec deploy/gvmd -c gvmd -- gvmd --get-users --verbose

# GMP reachable over TCP (no ingress — port-forward)
kubectl -n gvmd port-forward svc/gvmd 9390:9390 &
# then, with python-gvm or gvm-tools installed locally:
# gvm-cli --gmp-username <user> --gmp-password <pw> tls --hostname localhost --port 9390 --xml "<get_version/>"
```

## Faraday hookup

Once the pod is `Running`, configure Faraday's GVM/OpenVAS runner with:

- Host: `gvmd.gvmd.svc.cluster.local`
- Port: `9390`
- gvm_user / gvm_passwd: the `gvm_user`/`gvm_password` values seeded above

## Notes

- Internal DNS: `gvmd.gvmd.svc.cluster.local:9390`.
- Two PVCs: `gvmd-postgres-data` (4Gi, Postgres data) and `gvmd-data` (2Gi,
  gvmd's `/var/lib/gvm` — certs, tickets, report exports). Everything else
  is `emptyDir` — see "Architecture notes" for why.
- Not deployed (unneeded for Faraday's GMP connection): `gsad`/`gsa` (web
  UI), `nginx`/`gvm-config` (UI TLS termination), `gvm-tools`,
  `pg-gvm-migrator` (only needed for a future Postgres major-version
  upgrade).

## Troubleshooting

- **Pod stuck `Init:x/9` for a long time**: check which initContainer is
  running with `kubectl -n gvmd describe pod` — same feed-download bottleneck
  as `openvas-scanner`'s `vt-feed`; check node-local disk pressure if it's
  dramatically slower than a couple of minutes per feed.
- **`gvmd` CrashLoopBackOff citing Postgres connection errors**: confirm
  `pg-gvm` is `Running` and its readiness probe (`pg_isready`) is passing —
  `gvmd`'s startup script polls for `/var/lib/postgresql/started`, written by
  `pg-gvm` once initialization completes, before it will connect.
- **`gvmd` can't reach `ospd-openvas`**: confirm both containers mount the
  same `ospd-socket` emptyDir at `/run/ospd`.
- **GMP unreachable on 9390**: check `gvmd`'s logs for a `--listen`/`--port`
  argument error — see "Architecture notes" on the unverified `GVMD_ARGS`
  flags.
- **CrashLoopBackOff citing missing `POSTGRES_PASSWORD`/`GVM_USER`/`GVM_PASSWORD`**:
  the `gvmd-app` ExternalSecret hasn't synced yet — check
  `kubectl -n gvmd describe externalsecret gvmd-app` and re-seed Vault if any
  field is missing.
