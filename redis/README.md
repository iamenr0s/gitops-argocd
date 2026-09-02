# Redis

Deploys a single-replica, in-memory Redis instance via plain Kustomize manifests (no Helm chart) to namespace `databases`, managed by Argo CD. No persistence, no auth — used as a session/cache store for other apps in the cluster.

Upstream: `redis:7.2-alpine`

## Structure

```
application.yml   # ArgoCD Application — path-based Kustomize source
namespace.yml     # databases namespace
redis.yml         # Deployment + Service
kustomization.yml # Aggregates namespace.yml + redis.yml
```

## Configuration

`redis.yml` starts Redis with `--save ""` and `--appendonly no` — RDB snapshots and AOF are both disabled, so **all data is lost on pod restart**. That's deliberate: this instance backs Authelia's session store (`authelia/values.yml`'s `session.redis.host: redis.databases.svc.cluster.local`), which tolerates a cold cache (users just re-authenticate). Don't point anything at this instance that needs durable storage — deploy a dedicated Redis (with `persistence.enabled` and its own PVC) for that instead.

No auth is configured (`requirepass` unset) — access relies entirely on the `databases` namespace being unreachable from outside the cluster network.

## Deploy

Commit and push — Argo CD will sync the app to namespace `databases`.

## Verification

```bash
# Pod
kubectl -n databases get deploy redis
kubectl -n databases rollout status deploy/redis

# Connectivity
kubectl -n databases exec deploy/redis -- redis-cli ping
# expect: PONG

# From a consumer's perspective (e.g. Authelia)
kubectl -n authelia exec deploy/authelia -- sh -c \
  'nc -zv redis.databases.svc.cluster.local 6379'
```

## Troubleshooting

- **Consumers losing sessions unexpectedly**: check for pod restarts (`kubectl -n databases get pods -o wide` for restart count) — with `--save ""`/`--appendonly no`, any restart wipes all keys.
- **`CrashLoopBackOff`**: check the liveness probe (`redis-cli ping`) isn't failing due to resource limits — `resources.limits.memory: 64Mi` is tight; raise it in `redis.yml` if Redis OOMs under load.
- **Other apps can't connect**: confirm they're targeting `redis.databases.svc.cluster.local:6379` (not `redis.redis...` — the Service lives in `databases`, not a `redis` namespace) and that no NetworkPolicy blocks cross-namespace traffic to `databases`.

## Notes

- Single replica, no `PodDisruptionBudget` — a node drain will briefly drop the cache.
- If a second consumer needs Redis with different durability/auth requirements, deploy a separate instance rather than changing this one's settings — it's shared.
