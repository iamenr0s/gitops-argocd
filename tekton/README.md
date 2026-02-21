# Tekton Pipelines (Argo CD App)

## Overview
- Deploys Tekton Pipelines from upstream manifests (latest) managed by Argo CD.
- Deploys Tekton Dashboard from upstream manifests and exposes it with a Traefik Ingress.
- Installs into namespace `tekton-pipelines`.

## Files
- `tekton/pipelines-manifests.application.yml`: Argo CD app applying latest Pipelines release via Kustomize remote.
- `tekton/pipelines-manifests/kustomization.yml`: References upstream `latest` pipeline manifest.
- `tekton/tekton-dashboard.manifests.application.yml`: Argo CD app applying latest Dashboard release and our extras.
- `tekton/dashboard-manifests/kustomization.yml`: References upstream `latest` dashboard manifest.
- `tekton/dashboard.ingress.yml`: Traefik Ingress exposing the Dashboard.
- `tekton/git-auth.externalsecret.yml`: ExternalSecret pulling Git credentials from Vault.
- `tekton/kustomization.yml`: Includes ExternalSecret and Ingress for Argo CD to apply.

## Deploy
- Pipelines latest: `kubectl apply -f tekton/pipelines-manifests.application.yml`
- Dashboard latest: `kubectl apply -f tekton/tekton-dashboard.manifests.application.yml`
- These apps pull `latest` release YAMLs from `infra.tekton.dev` and apply them with Kustomize. Argo CD will create the `tekton-pipelines` namespace and sync.
  - Note: We delete Tekton validating webhooks during initial install to avoid transient TLS issues; Tekton runs fine without them. If you want them, we can add a follow-up app to create them once the webhook certs are ready.

## Manual Verification
- Check CRDs installed:
  - `kubectl get crds | findstr tekton`
- Check controller pods:
  - `kubectl -n tekton-pipelines get pods -o wide`
  - `kubectl -n tekton-pipelines rollout status deployment/tekton-pipelines-controller` (name may vary by release)
- Confirm webhook service:
  - `kubectl -n tekton-pipelines get svc`
- Access the Dashboard via Traefik Ingress:
  - `https://tekton.apps.k8s.enros.me`
  - Inspect Ingress: `kubectl -n tekton-pipelines get ingress tekton-dashboard -o wide`
- Verify Git auth Secret materialized:
  - `kubectl -n tekton-pipelines get secret tekton-git-auth -o yaml`
  - It should be type `kubernetes.io/basic-auth` and annotated with `tekton.dev/git-0: https://github.com`.

## Notes
- This repository standardizes on the `.yml` extension for manifests and values.
- Runtime Git/Docker authentication should be sourced from Vault via External Secrets rather than hardcoding values.
- Using upstream releases keeps you on the latest Tekton without waiting for chart updates.

## Vault Setup for Git Credentials
- Required Vault path and keys:
  - Path: `secret/tekton/git`
  - Keys: `username`, `password`
- Example (run inside Vault pod or via your Vault CLI):
  - `export TOKEN='<vault_token>'`
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault secrets enable -path=secret kv-v2 || true'`
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault kv put secret/tekton/git username="bot-user" password="<personal_access_token>"'`
- Vault policy (append to your External Secrets role):
  - Allow read: `path "secret/data/tekton/*" { capabilities = ["read"] }`

## How Tekton Uses These Credentials
- Tekton reads Secrets associated with a Run's ServiceAccount.
- Secrets annotated with `tekton.dev/git-0: https://github.com` are mounted to provide `~/.gitconfig` for Git.
- Reference: Tekton authentication docs.

## Updating
- These apps track `latest` upstream releases. To pin a specific version, change the remote URLs in the Kustomizations to a `previous/vX.Y.Z/release.yaml` path.
