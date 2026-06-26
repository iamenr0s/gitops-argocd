# k8s-hardening-rbac

Registers the CIS Kubernetes Benchmark RBAC hardening manifests from [k8s-hardening-cis](https://github.com/iamenr0s/k8s-hardening-cis) as an ArgoCD Application. Disables default ServiceAccount token automounting and provides a least-privilege Role example (CIS 5.1).

## Structure

```
application.yml   # ArgoCD Application — cross-repo Kustomize source (k8s-hardening-cis@master:03-rbac)
README.md         # This file
```

Source manifests live in the upstream repo at `03-rbac/`:
- `00-disable-default-sa-automount.yaml` — sets `automountServiceAccountToken: false` on default SAs
- `01-least-privilege-role-example.yaml` — least-privilege Role + RoleBinding template

## Deploy

This Application is registered but starts **OutOfSync** — no automated sync is configured (ARGO-04). Sync manually after reviewing the diff:

```bash
# Review what will be applied
argocd app diff k8s-hardening-rbac

# Apply (requires operator approval)
argocd app sync k8s-hardening-rbac
```

Phase 4 CI will automate this trigger once the pipeline is in place. Until then, sync is a manual operator step.

## Verification

```bash
# Check Application status (expect: Source repoURL=k8s-hardening-cis, Health=Unknown, Sync=OutOfSync)
argocd app get k8s-hardening-rbac

# Validate Kustomize rendering of the source manifests (no cluster access required)
kubectl kustomize https://github.com/iamenr0s/k8s-hardening-cis.git/03-rbac?ref=master

# After sync: confirm ServiceAccounts have automount disabled
kubectl get serviceaccount default -o jsonpath='{.automountServiceAccountToken}'
```

## Notes

- **Target namespace caveat (D-07):** The list of namespaces this RBAC hardening targets is maintained in `vars/cluster.yml` in the k8s-hardening-cis repo. If you add or remove namespaces there, any per-namespace overlays here must be updated manually — there is no automated propagation between the two repos.
- NetworkPolicy enforcement requires a CNI that implements NetworkPolicy (Calico, Cilium); flannel silently ignores NetworkPolicy objects.
- Source branch is `master` (k8s-hardening-cis), not `main` — this repo's branch differs from gitops-argocd's `main`.
