# Promtail

Deploys Promtail as a DaemonSet to collect Kubernetes pod logs and forward them to Loki in the `logging` namespace.

## Structure

```
application.yml   # ArgoCD Application — promtail Helm chart
values.yml        # Promtail config (Kubernetes discovery, Loki client URL)
```

## Deploy

```bash
kubectl apply -f promtail/application.yml
```

## Verification

```bash
# DaemonSet status
kubectl -n logging get ds -l app.kubernetes.io/name=promtail

# Pod status
kubectl -n logging get pods -l app.kubernetes.io/name=promtail

# Tail logs
kubectl -n logging logs ds/promtail -c promtail -f --tail=100
```

## Notes

- Loki push URL: `http://logging-loki.logging.svc.cluster.local:3100/loki/api/v1/push`
- Positions file: `/run/promtail/positions.yaml`
- Scrapes container logs from `/var/log/pods/*/*/*.log` with CRI parsing.
- Query in Grafana: `{namespace="logging"}` to verify ingestion.

## Troubleshooting

- **Cannot reach Loki**: verify the Loki service URL and confirm the `logging` namespace is running.
- **No logs collected**: check DaemonSet tolerations and host path mounts for `/var/log/pods`.
