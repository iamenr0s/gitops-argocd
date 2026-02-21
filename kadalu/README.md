# Kadalu Storage (Argo CD App)

## Overview
- Deploys Kadalu operator and storage configuration via Kustomize.
- Provides a GlusterFS-backed CSI storage class used by other apps (e.g., Grafana, InfluxDB).

## Files
- `application.yml`: Argo CD Application referencing local `kadalu` overlay.
- `kustomization.yml`: includes operator manifest (remote gist) and `kadalu-storage-generator.yml`.
- `kadalu-storage-generator.yml`: storage pool configuration.

## Deploy
- Commit and push; Argo CD will sync to namespace `kadalu`.

## Manual Verification
- `kubectl -n kadalu get pods`
- `kubectl get sc` to confirm Kadalu storage class availability.
- Create a test PVC bound to the Kadalu storage class and verify it binds.

## Troubleshooting
- Operator not ready: ensure cluster nodes meet Kadalu requirements and network paths are reachable.

