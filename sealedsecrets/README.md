# Sealed Secrets (Argo CD App)

## Overview
- Installs Bitnami Sealed Secrets controller via Helm.
- Enables encrypting Kubernetes secrets for safe storage in Git.

## Files
- `application.yml`: Argo CD Application for chart `sealed-secrets`.
- `values.yaml`: Helm values (e.g., `fullnameOverride: sealed-secrets-controller`).

## Usage
- Encrypt a secret: `kubeseal --controller-name sealed-secrets-controller --controller-namespace sealed-secrets -n <ns> < secret.yaml > secret.sealed.yaml`
- Commit the sealed secret to the repo; Argo CD applies it and the controller decrypts on cluster.

## Manual Verification
- `kubectl -n sealed-secrets get pods`
- Create a test secret, seal it, apply, and confirm the unsealed Secret appears.

## Troubleshooting
- Controller name mismatch: ensure `kubeseal` flags match Helm values and namespace.

