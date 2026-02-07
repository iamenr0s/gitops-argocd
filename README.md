# GitOps Argo CD Apps

## Overview
- GitOps repository for managing Kubernetes apps via Argo CD.
- Each app lives in its own directory with:
  - one or more Argo CD Application manifests (e.g., `application.yml`, `*-controller.yml`, `*-crds.yml`)
  - optional `kustomization.yml` and manifests
  - `values.yaml`/`values.yml` for Helm‑managed apps
  - `README.md` with usage and verification steps

## Apps
- [`cert-manager/`](cert-manager/README.md): certificate management and ACME issuers
- [`sealedsecrets/`](sealedsecrets/README.md): encrypt Kubernetes secrets in Git
- [`traefik/`](traefik/README.md): ingress controller and routing
- [`monitoring/`](monitoring/README.md): Prometheus, Grafana, Alertmanager stack
- [`influxdb/`](influxdb/README.md): InfluxDB 2 with persistence and ingress
- [`kadalu/`](kadalu/README.md): Kadalu storage operator and CSI
- [`external-secrets/`](external-secrets/README.md): External Secrets Operator for provider‑backed secrets
- [`vault/`](vault/README.md): HashiCorp Vault deployment and bootstrap

## Workflow
- Make changes in app directories, commit, and push.
- Argo CD detects changes and syncs to cluster.
- Use app READMEs for verification commands and troubleshooting.

## Adding a New App
- Create Argo CD Application manifest(s) under `<app>/` with chart or kustomize sources.
- Add `<app>/values.yaml` (or `.yml`) if using Helm.
- Add `<app>/kustomization.yml` for overlays.
- Document usage in `<app>/README.md`.
- For charts that manage CRDs, consider splitting CRDs into a dedicated manifest and using sync waves (see `external-secrets/`).

## Manual Sync
- `argocd app sync <app-name>`
- `kubectl` commands in individual READMEs help verify runtime state.
