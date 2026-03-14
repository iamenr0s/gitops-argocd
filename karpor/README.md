# Karpor (Helm)

## Overview
- Deploys Karpor via the upstream Helm chart `kusionstack/karpor`, managed by Argo CD.
- AI features require an API token and base URL; the token is stored in Vault and surfaced through External Secrets.
- Service defaults to `ClusterIP`; adjust via Helm values if you plan to expose the dashboard externally.

## Files
- `karpor/application.yml`: Argo CD Application pointing to the Karpor chart and `karpor/values.yml`.
- `karpor/values.yml`: Helm values (replicas, images, AI settings, etc.).
- `karpor/kustomization.yml`: Includes `namespace.yml` and `ai.externalsecret.yml`.
- `karpor/ai.externalsecret.yml`: ExternalSecret that creates Secret `karpor-ai` from Vault.
- `karpor/namespace.yml`: Namespace manifest for `karpor`.

## Deploy
- `kubectl apply -f karpor/application.yml`
- Argo CD will create the `karpor` namespace, reconcile the ExternalSecret from Vault, and install Karpor.

## Vault
- ClusterSecretStore: `vault-backend`
- Path: `secret/karpor/helm`
- Keys:
  - `ai_auth_token` (required for AI features)
  - `ai_base_url` (optional, default `https://api.openai.com/v1`)

## Vault Setup (kubectl-only)
- Variables:
  - `export TOKEN='<vault_token>'`
  - `export AI_AUTH_TOKEN='<your_ai_token>'`
  - `export AI_BASE_URL='https://api.openai.com/v1'`
- Create read policy for Karpor:
  ```bash
  cat > karpor-helm.hcl <<'EOF'
  path "secret/data/karpor/*" { capabilities = ["read"] }
  EOF
  kubectl cp karpor-helm.hcl vault/vault-0:/tmp/karpor-helm.hcl -n vault -c vault
  kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault policy write karpor-helm /tmp/karpor-helm.hcl'
  ```
- Bind policy to External Secrets role (append to existing policies as needed):
  ```bash
  kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault write auth/kubernetes/role/external-secrets \
    bound_service_account_names="external-secrets" \
    bound_service_account_namespaces="external-secrets" \
    policies="karpor-helm" ttl="1h"'
  ```
- Ensure KV v2 and seed secrets:
  ```bash
  kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault secrets enable -path=secret kv-v2 || true'
  kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault kv put secret/karpor/helm ai_auth_token='"$AI_AUTH_TOKEN"' ai_base_url='"$AI_BASE_URL"''
  ```

## Wiring the AI Token
- The upstream chart expects `server.ai.authToken` in Helm values. We avoid committing secrets by keeping the token in Vault:
  - Runtime Secret: `karpor-ai` is materialized in namespace `karpor` from Vault (see `ai.externalsecret.yml`).
  - To activate AI features without committing secrets, set Helm parameters via Argo CD CLI:
    ```bash
    argocd app set karpor -p server.ai.authToken=$AI_AUTH_TOKEN -p server.ai.baseUrl=$AI_BASE_URL
    argocd app sync karpor --prune --refresh
    ```
  - Alternatively, if your Argo CD supports Helm `valuesFrom`, you can create a Secret in `argocd` with a `values.yaml` and reference it from the Application.

## Manual Verification
- Check ExternalSecret:
  - `kubectl -n karpor describe externalsecret karpor-ai`
  - Force reconcile: `kubectl -n karpor annotate externalsecret karpor-ai reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite`
- Confirm Secret and keys:
  - `kubectl -n karpor get secret karpor-ai -o jsonpath='{.data.AI_AUTH_TOKEN}' | base64 -d; echo`
  - `kubectl -n karpor get secret karpor-ai -o jsonpath='{.data.AI_BASE_URL}' | base64 -d; echo`
- Validate deployment:
  - `kubectl -n karpor get pods`
  - `kubectl -n karpor get svc`

## Notes
- Chart repo: `https://kusionstack.github.io/charts` (chart `karpor`, version pinned in `application.yml`).
- `values.yml` sets `server.ai.baseUrl` to `https://api.openai.com/v1` and leaves `authToken` blank by default.
- Consider configuring Ingress or changing `server.serviceType` if you need external access.