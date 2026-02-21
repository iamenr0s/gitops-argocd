# Traefik Ingress Controller (Argo CD App)

## Overview
- Deploys Traefik via the official Helm chart managed by Argo CD.
- App manifest: `traefik/application.yml` references the chart and `traefik/values.yml`.
- Kustomize resources: `traefik/kustomization.yml` includes `certificate.yml` for TLS defaults.

## Prerequisites
- A running Kubernetes cluster and Argo CD.
- Optional: `cert-manager` for automatic TLS issuance.
- For bare‑metal or non‑cloud LB: set `service.externalIPs` in `traefik/values.yml`.

## Configuration Highlights
- `service.type`: `LoadBalancer` (default). For bare‑metal, provide `externalIPs`.
- `providers.kubernetesIngress.publishedService.enabled: true` to publish the service for ingress status.
- Dashboard route enabled: `ingressRoute.dashboard.enabled: true` and `matchRule` set to your host.
- Ports: `web` (80) and `websecure` (443) exposed; TLS enabled for `websecure`.
- Health check: Argo CD service health is ignored via annotation to avoid waiting on LB IP assignment.

## Files
- `traefik/application.yml`: Argo CD Application sourcing the chart and values.
- `traefik/values.yml`: Helm values controlling Traefik.
- `traefik/kustomization.yml`: Kustomize overlay.
- `traefik/certificate.yml`: Default TLS certificate resource (optional, adjust as needed).

## Deploy
- Commit and push changes; Argo CD will sync the Traefik app.
- Namespace is created automatically by Argo CD when syncing the application.

## Manual Verification
- Check pods:
  - `kubectl -n traefik get pods -o wide`
  - `kubectl -n traefik rollout status deploy/traefik`
- Check service:
  - `kubectl -n traefik get svc traefik -o yaml`
  - If using `externalIPs`, curl the IP: `curl -I http://<external-ip>/` and `curl -Ik https://<external-ip>/`
- Dashboard (port‑forward):
  - `kubectl -n traefik port-forward svc/traefik 9000:9000`
  - Open `http://localhost:9000/dashboard/`

## Argo CD Health Note
- To prevent Traefik app health from being blocked by `LoadBalancer` provisioning delays, the service has:
  - `argocd.argoproj.io/ignore-healthcheck: "true"` under `service.annotations` in `traefik/values.yml`.
- Manual annotation (optional immediate test):
  - `kubectl -n traefik annotate service traefik argocd.argoproj.io/ignore-healthcheck="true" --overwrite`

## Troubleshooting
- Service stuck in `Pending`: use `externalIPs` or switch `service.type` to `NodePort` for local testing.
- No routes working: confirm `ingressClass.name` is `traefik` and your Ingress/IngressRoute objects reference it.
- TLS issues: ensure `certificate.yml` or cert‑manager issuers/secrets exist for your hosts.
- Logs:
  - `kubectl -n traefik logs deploy/traefik`
- Increase log verbosity in `values.yml` with `logs.general.level: DEBUG`.

## Updating
- Adjust chart version in `traefik/application.yml` `targetRevision`.
- Modify `traefik/values.yml` for ports, entrypoints, TLS, and providers.
