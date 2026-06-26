# k8s-hardening-resource-governance

Registers the CIS Kubernetes Benchmark resource governance hardening manifests from [k8s-hardening-cis](https://github.com/iamenr0s/k8s-hardening-cis) as an ArgoCD Application. Applies LimitRange (default container limits) and ResourceQuota (namespace-level resource caps) to prevent noisy-neighbor denial-of-service (CIS 5.7).

## Structure

```
application.yml   # ArgoCD Application — cross-repo Kustomize source (k8s-hardening-cis@master:07-resource-governance)
README.md         # This file
```

Source manifests live in the upstream repo at `07-resource-governance/`:
- `limitrange.yaml` — default CPU/memory limits and requests for containers
- `resourcequota.yaml` — namespace-level hard caps on pods, CPU, memory, and services

## Deploy

This Application is registered but starts **OutOfSync** — no automated sync is configured (ARGO-04). Sync manually after reviewing the diff:

```bash
# Review what will be applied
argocd app diff k8s-hardening-resource-governance

# Apply (requires operator approval)
argocd app sync k8s-hardening-resource-governance
```

Phase 4 CI will automate this trigger once the pipeline is in place. Until then, sync is a manual operator step.

## Verification

```bash
# Check Application status (expect: Source repoURL=k8s-hardening-cis, Health=Unknown, Sync=OutOfSync)
argocd app get k8s-hardening-resource-governance

# Validate Kustomize rendering of the source manifests (no cluster access required)
kubectl kustomize https://github.com/iamenr0s/k8s-hardening-cis.git/07-resource-governance?ref=master

# After sync: confirm LimitRange and ResourceQuota exist in target namespaces
kubectl get limitrange,resourcequota -n <target-ns>
```

## Notes

- **Target namespace caveat (D-07):** The list of namespaces this resource governance targets is maintained in `vars/cluster.yml` in the k8s-hardening-cis repo. If you add or remove namespaces there, any per-namespace overlays here must be updated manually — there is no automated propagation between the two repos.
- Review the LimitRange default values (`limitrange.yaml`) against your actual workload resource profiles before syncing to production namespaces — overly restrictive defaults will cause pods to fail admission.
- Source branch is `master` (k8s-hardening-cis), not `main` — this repo's branch differs from gitops-argocd's `main`.
