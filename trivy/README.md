# Trivy Operator

Deploys Aqua Security Trivy Operator via the official Helm chart, managed by Argo CD. Provides vulnerability scanning, config audit, and SBOM generation for cluster workloads.

## Structure

```
application.yml   # ArgoCD Application — multi-source (chart + values + kustomize)
values.yml        # Helm values (scanner settings, storage, node-collector scheduling)
kustomization.yml # Kustomize overlay (namespace only)
namespace.yml     # trivy-system namespace
```

## Deploy

Commit and push — Argo CD will sync the Trivy app into the `trivy-system` namespace.

## Verification

```bash
# Pods and controllers
kubectl -n trivy-system get pods -o wide
kubectl -n trivy-system get deploy,ds,job

# Check operator logs
kubectl -n trivy-system logs deploy/trivy-operator -c trivy-operator --tail=200

# Verify ServiceMonitor (enabled in values.yml)
kubectl -n trivy-system get servicemonitor

# Verify reports are being created (CRDs installed by the chart)
kubectl get vulnerabilityreports.aquasecurity.github.io -A | head
kubectl get configauditreports.aquasecurity.github.io -A | head
```

## Notes

- Argo CD uses `ignoreDifferences` for CRDs to avoid drift on auto-managed annotations.
- Node collector scheduling is tuned in [values.yml](file:///c:/Users/enros/Development/gitops-argocd/trivy/values.yml) with tolerations for `control-plane` / `master` taints and `useNodeSelector=true`.
- Trivy cache/storage is configured via `trivy.storageClassName` and `trivy.storageSize` in [values.yml](file:///c:/Users/enros/Development/gitops-argocd/trivy/values.yml).

## Troubleshooting

- **node-collector Pending**: ensure tolerations exist for your node taints (control-plane/master) and review `nodeCollector.*` in `values.yml`.
- **No reports generated**: confirm the operator is running and has RBAC; check operator logs for scan job errors.
- **High resource usage**: lower concurrency (`operator.scanJobsConcurrentLimit`) and tune `trivy.resources`.
