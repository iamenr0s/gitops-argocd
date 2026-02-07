# External Secrets (Argo CD App)

## Overview
- Deploys External Secrets Operator using two Argo CD Applications: one for CRDs and one for the controller.
- Safely installs and upgrades CRDs ahead of the controller using sync waves.
- Manages `ExternalSecret`, `SecretStore`, `ClusterSecretStore`, `ClusterExternalSecret`, and related CRDs.

## Files
- `external-secrets/external-secrets-crds.yml`: installs CRDs only (`installCRDs: true`, components disabled).
- `external-secrets/external-secrets-controller.yml`: deploys the operator with your Helm values.
- `external-secrets/values.yml`: Helm values for the controller (CRDs disabled here).

## Chart Version
- Chart `targetRevision: 1.3.2` is set in both application manifests.
- Bump both `targetRevision` fields together when upgrading.

## Configuration Highlights
- Controller `values.yml` sets `installCRDs: false` because CRDs are handled by the CRD application.
- Webhook and certificate management are created by the controller (`webhook.create: true`, `certController.create: true`).
- Sync order is enforced via annotations: CRDs wave `-5`, controller wave `0`.
- Sync options include `CreateNamespace=true` and `ApplyOutOfSyncOnly=true` for efficient syncs.
- CRD application uses `ServerSideApply=true` and `Prune=false` to avoid accidental CRD deletions.

## Deploy
- Commit and push; Argo CD creates the `external-secrets` namespace and syncs the apps.
- The controller runs with `replicaCount: 1` by default; adjust in `values.yml` if needed.

## Using Providers
- Define a `SecretStore` (namespaced) or `ClusterSecretStore` (cluster‑wide) in your application repositories to connect to providers (Vault, AWS, GCP, Azure, Bitwarden, etc.).
- Create `ExternalSecret` resources that reference your store to materialize `Secret` objects.

## Verification
- `kubectl -n external-secrets get pods`
- `kubectl get crds | grep external-secrets` (or `findstr external-secrets` on Windows)
- Check controller logs: `kubectl -n external-secrets logs deploy/external-secrets`
- Create a test store and external secret; confirm the target `Secret` appears.

## Troubleshooting
- CRDs missing: ensure the CRD application is synced and still configured with `installCRDs: true`.
- Webhook/cert errors: the chart’s cert controller manages self‑signed certificates; enable `webhook.certManager.enabled` if you prefer cert‑manager and set `issuerRef`.
- Provider failures: inspect controller logs and validate provider credentials/configuration.

## Updating
- Update chart version in both application manifests and sync.
- Extend `values.yml` for metrics, service monitors, leader election, or resource tuning as needed.
