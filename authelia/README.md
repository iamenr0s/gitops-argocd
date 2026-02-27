# Authelia (Helm)

## Overview
- Deploys Authelia via the official `authelia` Helm chart, managed by Argo CD.
- Exposes an HTTPS ingress through Traefik with Let's Encrypt.
- Sensitive keys are sourced from Vault and materialized with External Secrets Operator.

## Files
- `authelia/application.yml`: Argo CD Application pointing to the Authelia chart and `authelia/values.yml`.
- `authelia/values.yml`: Helm values (ingress and environment secrets wiring).
- `authelia/kustomization.yml`: Includes `namespace.yml` and `secrets.externalsecret.yml`.
- `authelia/secrets.externalsecret.yml`: ExternalSecret that creates Secret `authelia-helm`.
- `authelia/namespace.yml`: Namespace manifest for `authelia`.

## Deploy
- `kubectl apply -f authelia/application.yml`
- Argo CD creates the namespace, reconciles secrets from Vault, and installs Authelia.

## Vault
- Path: `secret/authelia/helm`
- Keys:
  - `jwt_secret`
  - `session_secret`
  - `storage_encryption_key`

## Access
- URL: `https://authelia.apps.k8s.enros.me`
- TLS is managed by cert-manager via Traefik annotations.

## Notes
- The Helm chart is version-pinned in `application.yml`. Bump with care and test in a non-production environment first.
- The `values.yml` maps secret keys to environment variables consumed by Authelia.