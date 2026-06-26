# k8s-hardening-kyverno-policies

Registers the CIS Kubernetes Benchmark Kyverno admission-control policies from [k8s-hardening-cis](https://github.com/iamenr0s/k8s-hardening-cis) as an ArgoCD Application. Deploys 6 ClusterPolicies in Audit mode targeting pod-level security controls (CIS 5.2/5.7).

**Sync-wave dependency:** This Application is annotated `sync-wave: "1"` — it deploys AFTER the existing `kyverno` operator Application (unannotated = wave 0), guaranteeing the Kyverno CRDs and webhook are ready before the ClusterPolicy objects are applied.

## Structure

```
application.yml   # ArgoCD Application — cross-repo Kustomize source (k8s-hardening-cis@master:06-admission-policies-kyverno), sync-wave 1
README.md         # This file
```

Source manifests live in the upstream repo at `06-admission-policies-kyverno/`:
- `disallow-host-namespaces.yaml` — 2 ClusterPolicy docs: `disallow-host-namespaces` + `disallow-host-path` (CIS 5.2.2/5.2.3)
- `disallow-latest-tag.yaml` — blocks `:latest` image references (CIS 5.5)
- `disallow-privileged.yaml` — blocks privileged containers (CIS 5.2.1)
- `require-non-root.yaml` — requires non-root user context (CIS 5.2.6)
- `require-resource-limits.yaml` — requires CPU/memory limits (CIS 5.2)

All 6 ClusterPolicies use `validationFailureAction: Audit` — they report violations without blocking workloads. Enforcement mode (`Enforce`) is a Phase 4 decision.

## Deploy

This Application is registered but starts **OutOfSync** — no automated sync is configured (ARGO-04). Sync manually after reviewing the diff:

```bash
# Sync the operator first (if not already synced)
argocd app sync kyverno

# Review what will be applied (policies app, wave 1)
argocd app diff k8s-hardening-kyverno-policies

# Apply (requires operator approval)
argocd app sync k8s-hardening-kyverno-policies
```

Phase 4 CI will automate this trigger once the pipeline is in place. Until then, sync is a manual operator step.

## Verification

```bash
# Check Application status (expect: Source repoURL=k8s-hardening-cis, Health=Unknown, Sync=OutOfSync)
argocd app get k8s-hardening-kyverno-policies

# Validate Kustomize rendering of the source manifests (no cluster access required — should show 6 ClusterPolicies)
kubectl kustomize https://github.com/iamenr0s/k8s-hardening-cis.git/06-admission-policies-kyverno?ref=master

# After sync: confirm ClusterPolicies are registered
kubectl get clusterpolicies

# Check audit violations (expect entries in Audit mode, no blocking)
kubectl get policyreports -A
```

## Notes

- **Sync-wave ordering (ARGO-03):** `sync-wave: "1"` ensures policies deploy after the Kyverno operator (wave 0, unannotated). Never remove this annotation — applying ClusterPolicies before the CRDs exist will fail.
- **Audit mode only (GOPS-03/D-06):** All 6 policies use `validationFailureAction: Audit`. Do not flip to `Enforce` until violation review is complete — enforcing immediately risks blocking legitimate workloads.
- **Namespace ownership:** The `kyverno` namespace is owned by the existing `kyverno` operator Application. This app uses `CreateNamespace=false` — never add `CreateNamespace=true` here.
- **Source branch is `master` (k8s-hardening-cis):** not `main` — the source repo's default branch differs from this repo's `main`.
- **5 files = 6 policies:** `disallow-host-namespaces.yaml` carries two `---`-separated ClusterPolicy documents; the Kustomize root lists 5 files but ArgoCD reconciles 6 objects.
