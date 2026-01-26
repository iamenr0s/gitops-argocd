#!/bin/bash
echo "=== TRAEFIK SERVICE DEBUG ==="

# 1. What does ArgoCD think the state is?
echo -e "\n1. ArgoCD Status:"
argocd app get traefik -o json | jq '.status | {health: .health, sync: .sync, resources: .resources[] | select(.kind=="Service")}'

# 2. What's actually in the cluster?
echo -e "\n2. Actual Service in Cluster:"
kubectl get service traefik -n traefik -o yaml | yq eval '
  {
    name: .metadata.name,
    type: .spec.type,
    ports: .spec.ports,
    selector: .spec.selector,
    clusterIP: .spec.clusterIP,
    annotations: .metadata.annotations
  }' -

# 3. What would Helm create?
echo -e "\n3. What Helm wants to create:"
if [ -f "traefik/values.yaml" ]; then
  helm template traefik traefik/traefik -f traefik/values.yaml -n traefik | yq eval 'select(.kind=="Service" and .metadata.name=="traefik") | {
    name: .metadata.name,
    type: .spec.type,
    ports: .spec.ports,
    selector: .spec.selector
  }' -
fi

# 4. Check for common LoadBalancer issues
echo -e "\n4. LoadBalancer Status (if applicable):"
kubectl get service traefik -n traefik -o jsonpath='{.status.loadBalancer}' | jq '.'
