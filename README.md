# GitOps Argo CD Apps

## Overview
- GitOps repository for managing Kubernetes apps via Argo CD.
- Each app lives in its own directory with:
  - one or more Argo CD Application manifests (e.g., `application.yml`, `*-controller.yml`, `*-crds.yml`)
  - optional `kustomization.yml` and manifests
  - `values.yml` for Helm‑managed apps
  - `README.md` with usage and verification steps

## Prerequisites
- A Kubernetes cluster with `kubectl` access and Argo CD installed/configured.
- Helm and Kustomize available locally for optional manual operations.
- Optional: `external-secrets` and `vault` for secret management across apps.

## Apps
- [`cert-manager/`](cert-manager/README.md): certificate management and ACME issuers
- [`sealedsecrets/`](sealedsecrets/README.md): encrypt Kubernetes secrets in Git
- [`traefik/`](traefik/README.md): ingress controller and routing
- [`monitoring/`](monitoring/README.md): Prometheus, Grafana, Alertmanager stack
- [`logging/`](logging/README.md): Grafana Loki with S3 credentials sourced from Vault via External Secrets
- [`promtail/`](promtail/README.md): Promtail DaemonSet shipping Kubernetes logs to Loki
- [`influxdb/`](influxdb/README.md): InfluxDB 2 with persistence and ingress
- [`kadalu/`](kadalu/README.md): Kadalu storage operator and CSI
- [`external-secrets/`](external-secrets/README.md): External Secrets Operator for provider‑backed secrets
- [`vault/`](vault/README.md): HashiCorp Vault deployment and bootstrap
- [`harbor/`](harbor/README.md): Harbor registry with admin secret sourced from Vault via External Secrets
- [`kubescape/`](kubescape/README.md): Kubescape operator for continuous configuration and image vulnerability scanning
- [`tekton/`](tekton/README.md): Tekton Pipelines and Dashboard via upstream manifests with Traefik Ingress
- [`keycloak/`](keycloak/README.md): Keycloak via Bitnami Helm chart with Traefik Ingress and Vault-backed secrets

## Repository Structure
- Each app directory contains Argo CD application manifest(s), optional Kustomize overlays, and Helm values.
- CRD‑heavy charts may split into `*-crds.yml` and controller `application.yml` with sync waves to ensure safe upgrades.
- Namespaces are created via Argo CD (`CreateNamespace=true`) or explicit `namespace.yml` files.

## Workflow
- Make changes in app directories, commit, and push.
- Argo CD detects changes and syncs to cluster.
- Use app READMEs for verification commands and troubleshooting.

## Adding a New App
- Create Argo CD Application manifest(s) under `<app>/` with chart or kustomize sources.
- Add `<app>/values.yml` if using Helm.
- Add `<app>/kustomization.yml` for overlays.
- Document usage in `<app>/README.md`.
- For charts that manage CRDs, consider splitting CRDs into a dedicated manifest and using sync waves (see `external-secrets/`).

## Conventions
- Use `.yml` extension consistently for manifests and Helm values.
- Use sync waves to order CRDs before controllers (`argocd.argoproj.io/sync-wave: -5` for CRDs, `0` for controllers).
- Annotate services that may block health on LB provisioning with `argocd.argoproj.io/ignore-healthcheck: "true"` when appropriate.
- Store runtime credentials (e.g., Tekton Git bot) in Vault and surface via External Secrets; do not commit secrets or place them in Helm values.

## Secret Management
- Secrets are managed via External Secrets Operator reading from providers like Vault.
- See `external-secrets/README.md` for provider setup and `vault/README.md` for Vault bootstrap.
- App READMEs document the specific `ExternalSecret` and required Vault policies/paths.

## Manual Sync
- `argocd app sync <app-name>`
- `kubectl` commands in individual READMEs help verify runtime state.

## Verification
- After syncing, check pods and services in the app namespace.
- For Helm‑managed apps, validate ingress hosts and TLS issuance where applicable.
- For apps using External Secrets, describe `externalsecret` objects and confirm backed Kubernetes `Secret` contents.
