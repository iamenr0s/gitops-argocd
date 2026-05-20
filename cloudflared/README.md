# cloudflared

Deploys the [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) connector (`cloudflared`) as a Kubernetes Deployment, managed by Argo CD. Establishes an outbound tunnel from the cluster to Cloudflare's network — no inbound ports or LoadBalancer required.

## Structure

```
application.yml                       # ArgoCD Application — kustomize path
deployment.yml                        # cloudflared Deployment (2 replicas for HA)
namespace.yml                         # cloudflared namespace
tunnel-credentials.externalsecret.yml # ESO — creates Secret cloudflared-credentials from Vault
kustomization.yml                     # Aggregates all resources
```

## Prerequisites

1. Create a Cloudflare Tunnel in the [Zero Trust dashboard](https://one.dash.cloudflare.com/):
   - **Networks → Tunnels → Create a tunnel** → choose **Cloudflared** as the connector
   - Copy the **tunnel token** shown during setup
2. Configure tunnel routes (public hostnames or private networks) in the dashboard — no changes to this repo are needed for routing config

## Vault Setup

Seed the tunnel token before the first sync:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=${TOKEN} vault kv put secret/cloudflared/credentials \
    tunnel_token='<paste-tunnel-token-here>'
"
```

### Vault Policy

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=${TOKEN} \
  vault policy write cloudflared - <<EOF
path \"secret/data/cloudflared/*\" {
  capabilities = [\"read\"]
}
EOF
"
```

### Extend ESO Role

```bash
CURRENT=$(kubectl exec -n vault vault-0 -c vault -- sh -c \
  'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault read -field=policies auth/kubernetes/role/external-secrets' \
  | tr -d '[]' | tr ' ' ',')

kubectl exec -n vault vault-0 -c vault -- sh -c \
  'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault write auth/kubernetes/role/external-secrets \
    bound_service_account_names="external-secrets" \
    bound_service_account_namespaces="external-secrets" \
    policies="'"$CURRENT"',cloudflared" ttl="1h"'
```

## Deploy

Commit and push — Argo CD syncs `cloudflared/application.yml` to the cluster. Add the Application to your root App-of-Apps if not already present.

```bash
git add cloudflared/ && git commit -m "feat(cloudflared): add ArgoCD application" && git push
```

## Verification

```bash
# Pods running (2 replicas)
kubectl -n cloudflared get pods

# ExternalSecret synced
kubectl -n cloudflared describe externalsecret cloudflared-credentials

# Force reconcile ExternalSecret if needed
kubectl -n cloudflared annotate externalsecret cloudflared-credentials \
  reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite

# Confirm credentials secret exists
kubectl -n cloudflared get secret cloudflared-credentials

# Tunnel connected — check logs
kubectl -n cloudflared logs -l app=cloudflared --tail=20

# Liveness probe health
kubectl -n cloudflared exec -it deploy/cloudflared -- wget -qO- http://localhost:2000/ready
```

A healthy `cloudflared` pod logs `Connection registered` and the dashboard shows the connector as **Healthy**.

## Notes

- **Replicas**: 2 for high availability — Cloudflare load-balances across both connectors automatically
- **Image**: pinned to `cloudflare/cloudflared:2024.10.0`; update the tag in `deployment.yml` to upgrade
- **Routing config**: all tunnel ingress rules (public hostnames, private networks) are managed in the Cloudflare Zero Trust dashboard, not in this repo
- **No ingress/service needed**: cloudflared makes outbound connections only

## Troubleshooting

- **CrashLoopBackOff**: tunnel token is wrong or not yet seeded in Vault — check `TUNNEL_TOKEN` is set: `kubectl -n cloudflared exec deploy/cloudflared -- env | grep TUNNEL`
- **ExternalSecret not syncing**: verify Vault policy covers `secret/data/cloudflared/*` and the ESO role includes `cloudflared`
- **Tunnel shows Unhealthy in dashboard**: check pod logs for auth errors; ensure the token belongs to the correct Cloudflare account and tunnel
- **Liveness probe failing**: cloudflared metrics server starts after tunnel connection; if the cluster has no internet egress, the `/ready` endpoint never returns 200
- **Pods receive SIGTERM ~10s after start (graceful shutdown loop)**: the liveness probe on port 2000 is unreachable because cloudflared bound its metrics server to `127.0.0.1:<random>` instead of `0.0.0.0:2000`. Fix: pass `--metrics 0.0.0.0:2000` in the Deployment args. Without this flag cloudflared picks a random loopback port; the kubelet cannot reach loopback, the probe fails, and Kubernetes terminates the pod.
