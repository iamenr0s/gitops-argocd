# OpenVAS Scanner

Deploys [openvas-scanner](https://github.com/greenbone/openvas-scanner)
(Greenbone's vulnerability scanning engine, `openvasd`) via raw manifests —
upstream has no official Helm chart. Uses `iamenr0s/openvas-scanner` instead
of the upstream `greenbone/openvas-scanner` image because the upstream image
has no arm64 build; this cluster is all-arm64. No public ingress — the API
lets a client run arbitrary network scans with `NET_ADMIN`/`NET_RAW`, so it
stays ClusterIP-only, reachable in-cluster or via `kubectl port-forward`.

## Structure

```
application.yml                    # ArgoCD Application — kustomize path (no Helm chart upstream)
kustomization.yml                  # Aggregates all resources below
namespace.yml                      # openvas-scanner namespace
storage-key.externalsecret.yml     # ESO — creates Secret openvas-scanner-app (fs storage encryption key) from Vault
pvc.yml                            # 6 PVCs: VT feed, Notus feed, GPG keyring, /etc/openvas config, logs, scan storage
deployment.yml                     # One pod: feed initContainers + config initContainers, redis sidecar, openvasd
service.yml                        # ClusterIP :3000 -> openvasd
```

## Architecture notes

Mirrors upstream's [`compose/`](https://github.com/greenbone/openvas-scanner/tree/main/compose)
topology as closely as Kubernetes allows, run inside a single pod:

- **Feed volumes** (`openvas-vt-data`, `openvas-notus-data`, `openvas-gpg-data`)
  are populated by three one-shot initContainers using Greenbone's official
  feed images (`vulnerability-tests`, `notus-data`, `gpg-data` —
  `registry.community.greenbone.net/community/*`, all arm64-capable). They
  re-run on every pod (re)start; see "Updating feeds" below.
- **Config volume** (`openvas-config`, mounted at `/etc/openvas`) is written
  by two more initContainers (`configure-openvas-log`, `configure-openvas`)
  using the `iamenr0s/openvas-scanner` image itself, replicating upstream's
  `configure-openvas-log`/`configure-openvas` compose services — they read
  the config template baked into the image and rewrite it with the desired
  log level and `openvasd_server` URL (`http://localhost:3000`, since
  `openvas` and `openvasd` share the pod's network namespace).
- **Redis**: `openvas`/`openvasd` use Redis as their scan-results KB store
  over a Unix socket. Upstream's compose uses `ghcr.io/greenbone/redis-server`
  for this — **that image has no arm64 build**. The `redis` sidecar container
  substitutes vanilla `redis:7-alpine` (official, multi-arch), configured
  equivalently: Unix-socket-only (`--port 0`), no persistence (`--save ""`,
  `--appendonly no`), and a larger `--databases 128` so concurrent scans each
  get their own KB namespace. The socket lives on an `emptyDir` shared
  between the `redis` and `openvasd` containers — it's not meant to persist
  across restarts, matching upstream (`redis_socket_vol` there is also just a
  socket-holding volume, not a data volume).
- **Scan storage** (`openvasd-storage`, mounted at `/var/lib/openvasd/storage`):
  new addition, not in upstream's compose (which defaults to in-memory
  storage). `STORAGE_TYPE=fs` + this PVC persist scan configs/results/queue
  across pod restarts. `STORAGE_KEY` (from Vault) encrypts that data at rest.
- **API key auth**: not enabled by default. `openvasd` supports `X-API-KEY`
  auth (env `API_KEY`), but Kubernetes `httpGet` probes can't attach a header
  sourced from a Secret without inlining the key in plaintext into the pod
  spec — and since this service isn't exposed outside the cluster, the
  ClusterIP boundary is the access control. If you later add an Ingress here,
  set `API_KEY` and add a matching `httpHeaders` entry to both probes.

## Vault Setup

Seed the storage encryption key before first sync:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/openvas-scanner/helm \
    storage_key='<strong_random_key>'
"
```

### Vault Policy

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault policy write openvas-scanner - <<EOF
path \"secret/data/openvas-scanner/*\" {
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
    policies="'"$CURRENT"',openvas-scanner" ttl="1h"'
```

## Deploy

```bash
kubectl apply -f openvas-scanner/application.yml
# or
argocd app sync openvas-scanner --prune --refresh
```

First sync pulls the full VT feed (multi-GB) via the `vt-feed` initContainer
— the pod stays `Init:x/5` for several minutes on first boot.

## Verification

```bash
# ExternalSecret synced
kubectl -n openvas-scanner describe externalsecret openvas-scanner-app

# Pod (initContainers complete, then redis + openvasd both Running)
kubectl -n openvas-scanner get pods -o wide

# Feed/config initContainer logs, in order
kubectl -n openvas-scanner logs deploy/openvasd -c vt-feed
kubectl -n openvas-scanner logs deploy/openvasd -c notus-feed
kubectl -n openvas-scanner logs deploy/openvasd -c gpg-feed
kubectl -n openvas-scanner logs deploy/openvasd -c configure-openvas-log
kubectl -n openvas-scanner logs deploy/openvasd -c configure-openvas

# API reachable (no ingress — port-forward)
kubectl -n openvas-scanner port-forward svc/openvasd 3000:3000 &
curl -s http://localhost:3000/health/ready
curl -s http://localhost:3000/health/alive
```

## Notes

- No login/UI — `openvasd` is a REST API meant to be driven by a scan client
  (e.g. `scannerctl`, or a GVM stack's `gvmd`), not browsed directly.
- Internal DNS: `openvasd.openvas-scanner.svc.cluster.local:3000`.
- PVCs (`kadalu.kadalu-pool-replica3`): `openvas-vt-data` (8Gi, VT feed —
  largest), `openvas-notus-data` (2Gi), `openvas-gpg-data` (256Mi),
  `openvas-config` (256Mi), `openvas-log` (256Mi), `openvasd-storage` (2Gi,
  scan configs/results).
- Container needs `NET_ADMIN`/`NET_RAW`/`NET_BIND_SERVICE` capabilities to
  send raw scan probes — the image's Dockerfile already grants these via
  `setcap` on the `openvas` and `nmap` binaries, but the pod's
  `securityContext.capabilities` must also allow them at the container level
  (Kubernetes' default capability set includes `NET_RAW`/`NET_BIND_SERVICE`
  but not `NET_ADMIN`).

### Updating feeds

There's no in-cluster feed-refresh mechanism (no CronJob). The
`vt-feed`/`notus-feed`/`gpg-feed` initContainers re-copy the latest feed
content from their images on every pod (re)start, so to refresh:

```bash
kubectl -n openvas-scanner rollout restart deployment/openvasd
```

## Troubleshooting

- **Pod stuck `Init:x/5`**: expected on first boot (VT feed download); check
  which initContainer is running with `kubectl -n openvas-scanner describe
  pod` and tail its logs if it's taking unusually long.
- **`openvasd` CrashLoopBackOff citing Redis connection errors**: confirm the
  `redis` sidecar is `Running` and the `redis-socket` emptyDir is shared —
  both containers must mount it at `/run/redis`.
- **`openvasd` can't read `/etc/openvas/openvas.conf` / `openvas_log.conf`**:
  check the `configure-openvas`/`configure-openvas-log` initContainer logs —
  they write those files into the `openvas-config` PVC before the main
  container starts.
- **Scan results lost after a restart**: confirm `STORAGE_TYPE=fs` and the
  `openvasd-storage` PVC is mounted at `/var/lib/openvasd/storage` — the
  default upstream behavior (in-memory) would also explain this if that env
  var were ever removed.
- **CrashLoopBackOff citing missing `STORAGE_KEY`**: the
  `openvas-scanner-app` ExternalSecret hasn't synced yet — check
  `kubectl -n openvas-scanner describe externalsecret openvas-scanner-app`
  and re-seed Vault if `storage_key` is missing.
