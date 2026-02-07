# Monitoring Stack (Argo CD App)

## Overview
- Deploys `kube-prometheus-stack` (Prometheus, Alertmanager, Grafana, exporters) via Helm.
- Uses Traefik for ingress and cert-manager for webhook certificates.

## Files
- `application.yml`: Argo CD Application with Helm chart + local overlay.
- `values.yaml`: Helm values (ingress, operator settings, CRD job disabled, webhook patch disabled, cert-manager enabled).
- `kustomization.yml`: includes namespace and sealed Grafana credentials.
- `namespace.yml`: creates the `monitoring` namespace.
- `grafana-auth.sealed.yml`: sealed secret for Grafana admin credentials.

## Configuration Highlights
- Ingress hosts:
  - Prometheus: `prometheus.apps.k8s.enros.me`
  - Grafana: `grafana.apps.k8s.enros.me`
  - Alertmanager: `alertmanager.apps.k8s.enros.me`
- CRD differences ignored in Argo CD to avoid oversized annotation merges.
- Admission webhook certificate jobs disabled; cert-manager enabled to provision webhook certs.

## Deploy
- Commit and push; Argo CD will sync to namespace `monitoring`.

## Manual Verification
- `kubectl -n monitoring get pods`
- `kubectl -n monitoring get ingress`
- Access Grafana and Prometheus using configured hosts; Grafana admin credentials from sealed secret.

## Troubleshooting
- Long sync on hooks: confirm cert-manager is installed and webhook patch jobs are disabled in values.
- CRD errors: ignore differences configured; manage CRDs via chart or dedicated app if needed.

