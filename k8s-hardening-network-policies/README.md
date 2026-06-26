# k8s-hardening-network-policies

Registers the CIS Kubernetes Benchmark NetworkPolicy hardening manifests from [k8s-hardening-cis](https://github.com/iamenr0s/k8s-hardening-cis) as an ArgoCD Application. Applies default-deny-all egress/ingress plus DNS and intra-namespace allow rules (CIS 5.3).

## Structure

```
application.yml   # ArgoCD Application — cross-repo Kustomize source (k8s-hardening-cis@master:05-network-policies)
README.md         # This file
```

Source manifests live in the upstream repo at `05-network-policies/`:
- `00-default-deny-all.yaml` — default-deny NetworkPolicy (blocks all ingress/egress by default)
- `01-allow-dns.yaml` — allow egress to kube-system DNS (UDP/TCP 53)
- `02-allow-namespace-internal.yaml` — allow intra-namespace pod-to-pod traffic

## Deploy

This Application is registered but starts **OutOfSync** — no automated sync is configured (ARGO-04). Sync manually after reviewing the diff:

```bash
# Review what will be applied
argocd app diff k8s-hardening-network-policies

# Apply (requires operator approval)
argocd app sync k8s-hardening-network-policies
```

Phase 4 CI will automate this trigger once the pipeline is in place. Until then, sync is a manual operator step.

## Verification

```bash
# Check Application status (expect: Source repoURL=k8s-hardening-cis, Health=Unknown, Sync=OutOfSync)
argocd app get k8s-hardening-network-policies

# Validate Kustomize rendering of the source manifests (no cluster access required)
kubectl kustomize https://github.com/iamenr0s/k8s-hardening-cis.git/05-network-policies?ref=master

# After sync: confirm NetworkPolicies are present in target namespaces
kubectl get networkpolicies -n <target-ns>
```

## Notes

- **Target namespace caveat (D-07):** The list of namespaces this NetworkPolicy hardening targets is maintained in `vars/cluster.yml` in the k8s-hardening-cis repo. If you add or remove namespaces there, any per-namespace overlays here must be updated manually — there is no automated propagation between the two repos.
- **CNI requirement:** NetworkPolicy enforcement requires a CNI plugin that implements the NetworkPolicy API (Calico, Cilium, etc.). Flannel does **not** enforce NetworkPolicy objects — they will be silently ignored if flannel is your CNI.
- Source branch is `master` (k8s-hardening-cis), not `main` — this repo's branch differs from gitops-argocd's `main`.
