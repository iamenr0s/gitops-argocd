# Traefik

Deploys Traefik via the official Helm chart as the cluster ingress controller, managed by Argo CD. Exposes HTTP (80) and HTTPS (443) via a LoadBalancer service.

## Structure

```
application.yml   # ArgoCD Application — chart + values.yml
values.yml        # Helm values (service, dashboard, entrypoints, TLS)
kustomization.yml # Kustomize overlay
certificate.yml   # Default TLS certificate resource (optional)
```

## Deploy

Commit and push — Argo CD will sync the Traefik app. Namespace is created automatically.

## Verification

```bash
# Pods
kubectl -n traefik get pods -o wide
kubectl -n traefik rollout status deploy/traefik

# Service and external IP
kubectl -n traefik get svc traefik -o yaml

# Dashboard (port-forward)
kubectl -n traefik port-forward svc/traefik 9000:9000
# Open http://localhost:9000/dashboard/

# Test external connectivity
curl -I http://<external-ip>/
curl -Ik https://<external-ip>/
```

## Notes

- `service.type: LoadBalancer`; set `service.externalIPs` in `values.yml` for bare-metal.
- `providers.kubernetesIngress.publishedService.enabled: true` to publish the service for ingress status.
- Argo CD health check is bypassed via `argocd.argoproj.io/ignore-healthcheck: "true"` on the service annotation to avoid waiting on LB IP assignment.

## Troubleshooting

- **Service stuck in Pending**: set `externalIPs` in `values.yml` or change `service.type` to `NodePort`.
- **No routes working**: confirm `ingressClass.name: traefik` and Ingress/IngressRoute objects reference it.
- **TLS issues**: ensure `certificate.yml` or cert-manager issuers/secrets exist for your hosts.
- **Debug logs**: set `logs.general.level: DEBUG` in `values.yml` and check: `kubectl -n traefik logs deploy/traefik`.
