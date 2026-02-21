# Promtail – Argo CD App

## Overview
- Deploys Promtail as a DaemonSet to collect Kubernetes pod logs and push them to Loki.
- Targets the Loki service in the `logging` namespace.

## Files
- `application.yml`: Argo CD Application for the `promtail` Helm chart.
- `values.yml`: Promtail configuration with Kubernetes discovery and Loki client.

## Configuration
- Loki push URL: `http://logging-loki.logging.svc.cluster.local:3100/loki/api/v1/push`
- Positions file: `/run/promtail/positions.yaml`
- Scrapes container logs from `/var/log/pods/*/*/*.log` with CRI parsing.

## Deploy
- Apply the Argo CD application: `kubectl apply -f promtail/application.yml`

## Verify
- DaemonSet: `kubectl -n logging get ds -l app.kubernetes.io/name=promtail`
- Pods: `kubectl -n logging get pods -l app.kubernetes.io/name=promtail`
- Promtail logs: `kubectl -n logging logs ds/promtail -c promtail -f --tail=100`
- Loki ingestion:
  - Query in Grafana: `{namespace="logging"}` and adjust time range.

## Troubleshooting
- If Promtail cannot reach Loki, ensure the Loki service URL is correct and reachable from the cluster.
- Verify node permissions to read `/var/log/pods`; check DaemonSet tolerations and host path mounts if needed.
