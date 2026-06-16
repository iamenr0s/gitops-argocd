# Kyverno

Deploys [Kyverno](https://kyverno.io) policy engine via the official Helm chart, managed by Argo CD. Enforces admission policies and generates `PolicyReport` / `ClusterPolicyReport` resources consumed by [Policy Reporter](../policy-reporter/README.md).

## Structure

```
application.yml   # ArgoCD Application — multi-source (chart + values + kustomize)
values.yml        # Helm values (single-replica homelab tuning)
kustomization.yml # Kustomize overlay (namespace only)
namespace.yml     # kyverno namespace
```

## Deploy

Commit and push — Argo CD will sync Kyverno into the `kyverno` namespace.

```bash
git add kyverno/ && git commit -m "deploy: kyverno" && git push
```

No Vault secrets are required for Kyverno itself.

## Verification

```bash
# All four controllers running (admission, background, cleanup, reports)
kubectl -n kyverno get pods

# CRDs installed
kubectl get crds | grep kyverno

# Active cluster-wide policies
kubectl get clusterpolicy

# Active namespace-scoped policies
kubectl get policy -A

# Check admission controller webhook
kubectl get validatingwebhookconfigurations | grep kyverno
kubectl get mutatingwebhookconfigurations | grep kyverno
```

## Generating & Viewing Reports

Kyverno's `reportsController` automatically generates `PolicyReport` and `ClusterPolicyReport` resources as it evaluates resources against active policies.

```bash
# List all namespace-scoped policy reports
kubectl get policyreport -A

# List cluster-scoped policy reports
kubectl get clusterpolicyreport

# Inspect a specific report (shows pass/fail/warn/error results per rule)
kubectl describe policyreport <name> -n <namespace>
kubectl describe clusterpolicyreport <name>

# Count violations across the cluster
kubectl get policyreport -A -o json \
  | jq '[.items[].results[] | select(.result=="fail")] | length'

# List all failing results with resource details
kubectl get policyreport -A -o json | jq -r '
  .items[] | .metadata.namespace as $ns |
  .results[] | select(.result=="fail") |
  [$ns, .resources[0].name, .policy, .rule, .message] | @tsv'

# Watch the reports controller generating reports in real time
kubectl -n kyverno logs deploy/kyverno-reports-controller -f
```

### Triggering a background scan

Background scans run automatically on a schedule (default: every hour). To force an immediate re-evaluation of existing resources against all policies, annotate the background controller to restart it:

```bash
kubectl -n kyverno rollout restart deploy/kyverno-background-controller
```

### Testing a policy locally (dry-run)

Use the `kubectl-kyverno` CLI to validate resources against policies without applying them:

```bash
# Install (if not present)
kubectl kyverno version || brew install kyverno

# Test a policy against a manifest
kubectl kyverno apply <policy.yml> --resource <resource.yml>

# Test against all resources in the cluster (requires kubeconfig)
kubectl kyverno apply <policy.yml> -r clusterpolicyreport
```

### Dashboard

Policy reports are also visible in the [Policy Reporter UI](https://policy-reporter.apps.k8s.enros.me) (behind Authelia). See [policy-reporter/README.md](../policy-reporter/README.md).

## Notes

- All four controllers run at `replicas: 1` — this is intentional for a single-node homelab; see `values.yml`.
- `ServerSideApply=true` is required to bypass the 262144-byte annotation size limit on large CRDs.
- `ignoreDifferences` on `CustomResourceDefinition` resources (metadata.annotations, metadata.labels, spec.conversion, kube-apiserver managed fields) suppresses false-positive OutOfSync caused by kube-apiserver rewriting CRD metadata on admission.
- The `reportsController` must remain enabled (it is by default) for Policy Reporter to have data to display.

## Troubleshooting

- **App perpetually OutOfSync on CRDs**: known ArgoCD v3.x + ServerSideDiff interaction on `policies.kyverno.io` CRDs; `ignoreDifferences` suppresses the diff display but the controller may still flag OutOfSync. This is cosmetic — health remains `Healthy`.
- **Pods not starting**: check RBAC; the Helm chart creates the necessary ClusterRoles but ensure no PSP / security policy is blocking the kyverno namespace.
- **No PolicyReports generated**: confirm `reportsController` pod is running and no errors appear in its logs; verify at least one `ClusterPolicy` or `Policy` is active.
- **Webhook timeouts / admission delays**: inspect `kyverno-admission-controller` logs; consider adding `failurePolicy: Ignore` to non-critical policies while diagnosing.
- **Policy not enforcing**: check `validationFailureAction` in the policy spec — `Audit` logs violations without blocking; `Enforce` blocks the request.
