# Bootstrap

The root Argo CD `Application` for this repo's app-of-apps pattern. It globs every `Application` manifest in the repository (this repo's own manifests, not a separate charts repo) and applies them — that's how every other app in this repo gets registered with Argo CD without a manual `kubectl apply` per app.

## Structure

```
application.yml   # ArgoCD Application — directory source, no Kustomize
```

That's the only file. Unlike every other app in this repo, `bootstrap` has no `values.yml`, `namespace.yml`, or `kustomization.yml` — it doesn't deploy a workload, it deploys other `Application` objects.

## How it works

`spec.source.directory` (not `kustomize`) with `recurse: true` and an `include` glob:

```yaml
include: "*/application.yml,*/*-controller.yml,*/*-crds.yml,tekton/*.application.yml"
```

This is a plain-directory source deliberately, not Kustomize — Kustomize's default loader refuses to reference files outside its own root, which every app's `application.yml` does (they all point at Helm charts or paths elsewhere in the repo). A plain directory glob has no such restriction.

Because `bootstrap/application.yml` itself matches `*/application.yml`, `bootstrap` ends up managing itself once applied — no separate "meta-bootstrap" step needed after the first apply.

Sync wave `-100` ensures `bootstrap` reconciles before every other `Application` it creates (see [Key Conventions](../CLAUDE.md) for the rest of the wave/dependency ordering: `vault` → `external-secrets` → `cert-manager` → `traefik` → `postgresql` → everything else).

## Deploy (first-time bootstrap)

This is the **one** app still applied manually — something has to seed Argo CD before Argo CD can manage itself:

```bash
kubectl apply -f bootstrap/application.yml
```

After that, commits to any `application.yml` (new or edited) are picked up automatically the next time `bootstrap` syncs.

**Automated sync (`prune`/`selfHeal`) is intentionally not enabled** — see the `NOTE` comment in `application.yml`. The rollout is staged manually: apply, diff, sync, and verify adoption of every `Application` CR shows zero unexpected changes before flipping on `syncPolicy.automated`. Until then, sync `bootstrap` explicitly:

```bash
argocd app sync bootstrap
```

## Adding a new app

A new `<app>/application.yml` (or `*-crds.yml`/`*-controller.yml`) matching the `include` glob is picked up automatically — no edit to this file needed. Only broaden `include` if a new app's filename doesn't match the existing patterns (see `tekton/*.application.yml` for a precedent). CI (`.github/workflows/validate.yml`) fails any PR that adds a `kind: Application` file not covered by this glob.

## Verification

```bash
# Confirm bootstrap itself is registered and healthy
kubectl -n argocd get application bootstrap

# List every Application it's tracking
argocd app get bootstrap

# Confirm a specific app was picked up after a new application.yml was pushed
kubectl -n argocd get application <app-name>
```

## Troubleshooting

- **New app's `application.yml` not showing up as an Argo CD `Application`**: confirm the filename matches the `include` glob exactly; broaden it if not (see Adding a new app above).
- **`bootstrap` itself missing from `kubectl -n argocd get application`**: it hasn't been manually applied yet on this cluster — run the `kubectl apply -f bootstrap/application.yml` step above.
- **Changes not auto-applying**: automated sync is off by design (see Deploy above) — sync manually with `argocd app sync bootstrap`, or an individual app with `argocd app sync <app-name>`.
