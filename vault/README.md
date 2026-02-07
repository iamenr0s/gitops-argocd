# HashiCorp Vault (Argo CD App)

## Overview
- Deploys HashiCorp Vault via the official Helm chart managed by Argo CD.
- Includes additional manifests (RBAC, init job) to bootstrap Vault and integrate with cluster workloads.

## Files
- `vault/application.yml`: Argo CD Application referencing the HashiCorp Helm chart and local values.
- `vault/values.yml`: Helm values for Vault server configuration (storage, service type, HA, etc.).
- `vault/kustomization.yml`: Kustomize overlay for local resources.
- `vault/namespace.yml`: Namespace definition for `vault`.
- `vault/rbac.yml`: Service accounts/roles for Vault integration.
- `vault/init-job.yml`: Init job for bootstrapping tasks (e.g., unseal/setup/policies).

## Configuration Highlights
- Configure storage backend (e.g., Raft) and service exposure in `values.yml`.
- Adjust HA and resources to suit cluster capacity.
- Integrate with External Secrets by creating `SecretStore` pointing to Vault.

## Deploy
- Commit and push; Argo CD will sync to the `vault` namespace and apply overlay resources.

## Manual Verification
- `kubectl -n vault get pods`
- `kubectl -n vault logs statefulset/vault` (or deployment depending on chosen mode)
- Verify service and readiness: `kubectl -n vault get svc`

## Troubleshooting
- Init job failures: inspect `vault/init-job.yml` logs and ensure RBAC allows needed actions.
- Unseal/setup flow: confirm values and bootstrap logic match desired operational model.
- Storage issues: check PVCs/PV and Raft health.

## Updating
- Bump chart `targetRevision` in `vault/application.yml`.
- Tune `vault/values.yml` for performance, auth methods, and policies.
