# Cert-Manager (Argo CD App)

## Overview
- Installs Cert-Manager via Helm with CRDs.
- Adds cluster issuers and sealed secrets required for DNS/ACME.

## Files
- `application.yml`: Argo CD Application pointing to `charts.jetstack.io` and local overlay.
- `kustomization.yml`: includes issuer and secret resources.
- `cluster-issuer-letsencrypt-production.yml`, `cluster-issuer-letsencrypt-staging.yml`: ClusterIssuer definitions.
- `acme-contact.sealed.yml`, `cloudflare-api-token.sealed.yml`: sealed secrets for ACME email and DNS token.

## Configuration Highlights
- `installCRDs: true` is set in Helm values to install required CRDs.
- DNS provider credentials are stored as sealed secrets; decrypting requires the controller’s private key.

## Deploy
- Commit and push; Argo CD will sync the app and create the `cert-manager` namespace.

## Manual Verification
- `kubectl -n cert-manager get pods`
- `kubectl get clusterissuer`
- Issue a test certificate with an Ingress or Certificate resource and watch it become `Ready`.

## Troubleshooting
- Webhook failing: ensure CRDs installed and webhook service reachable.
- ACME/DNS errors: check provider token (Cloudflare) and domain/zone configuration.

