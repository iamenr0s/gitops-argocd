# k8s-hardening-pod-security

Registers the CIS Kubernetes Benchmark Pod Security hardening manifests from [k8s-hardening-cis](https://github.com/iamenr0s/k8s-hardening-cis) as an ArgoCD Application. Applies Pod Security Admission namespace labels (baseline/restricted) and provides a pod securityContext reference template (CIS 5.2).

## Structure

```
application.yml   # ArgoCD Application — cross-repo Kustomize source (k8s-hardening-cis@master:04-pod-security)
README.md         # This file
```

Source manifests live in the upstream repo at `04-pod-security/`:
- `namespace-psa-labels.yaml` — Namespace labels enabling PSA enforce/audit/warn modes
- `pod-security-context-template.yaml` — Reference securityContext for workload authors

## Deploy

This Application is registered but starts **OutOfSync** — no automated sync is configured (ARGO-04). Sync manually after reviewing the diff:

```bash
# Review what will be applied
argocd app diff k8s-hardening-pod-security

# Apply (requires operator approval)
argocd app sync k8s-hardening-pod-security
```

Phase 4 CI will automate this trigger once the pipeline is in place. Until then, sync is a manual operator step.

## Verification

```bash
# Check Application status (expect: Source repoURL=k8s-hardening-cis, Health=Unknown, Sync=OutOfSync)
argocd app get k8s-hardening-pod-security

# Validate Kustomize rendering of the source manifests (no cluster access required)
kubectl kustomize https://github.com/iamenr0s/k8s-hardening-cis.git/04-pod-security?ref=master

# After sync: confirm PSA labels on target namespaces
kubectl get namespace <target-ns> -o jsonpath='{.metadata.labels}' | jq .
```

## Notes

- **Target namespace caveat (D-07):** The list of namespaces this Pod Security hardening targets is maintained in `vars/cluster.yml` in the k8s-hardening-cis repo. If you add or remove namespaces there, any per-namespace overlays here must be updated manually — there is no automated propagation between the two repos.
- The `namespace-psa-labels.yaml` contains example namespace names; update to match your actual cluster namespaces before syncing.
- Source branch is `master` (k8s-hardening-cis), not `main` — this repo's branch differs from gitops-argocd's `main`.
