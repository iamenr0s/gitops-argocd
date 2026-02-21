# Logging (Loki) – Argo CD App

## Overview
- Deploys Grafana Loki via Helm and wires S3 credentials from Vault using External Secrets.
- Namespace `logging` is created and resources are ordered via sync waves.

## Files
- `application.yml`: Argo CD Application (Helm chart + local overlay).
- `values.yml`: Loki Helm values; enables single-binary and injects S3 env from Secret.
- `kustomization.yml`: includes `namespace.yml` and `loki-s3.externalsecret.yml`.
- `namespace.yml`: creates the `logging` namespace.
- `loki-s3.externalsecret.yml`: ExternalSecret that creates Secret `loki-s3` with AWS creds.

## Vault Setup (kubectl-only)
- Variables:
  - `export TOKEN='<vault_token>'`
  - `export AWS_ACCESS_KEY_ID='<key_id>'`
  - `export AWS_SECRET_ACCESS_KEY='<secret_key>'`
  - `export AWS_REGION='<region>'`
  - `export S3_BUCKET='<bucket>'`
  - `export S3_ENDPOINT='<https://s3.amazonaws.com | https://minio.example:9000>'`
- Create read policy for logging:
  - `cat > logging-s3-read.hcl <<'EOF'`
  - `path "secret/data/logging/*" { capabilities = ["read"] }`
  - `EOF`
  - `kubectl cp logging-s3-read.hcl vault/vault-0:/tmp/logging-s3-read.hcl -n vault -c vault`
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault policy write logging-s3-read /tmp/logging-s3-read.hcl'`
- Bind policy to External Secrets Operator role:
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault write auth/kubernetes/role/external-secrets bound_service_account_names="external-secrets" bound_service_account_namespaces="external-secrets" policies="logging-s3-read" ttl="1h"'`
  - If the role already exists with other policies, include them (e.g., `policies="harbor-admin,grafana-read,logging-s3-read"`).
- Ensure KV v2 enabled and seed secret:
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault secrets enable -path=secret kv-v2 || true'`
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault kv put secret/logging/s3 access_key_id='"$AWS_ACCESS_KEY_ID"' secret_access_key='"$AWS_SECRET_ACCESS_KEY"' region='"$AWS_REGION"' bucket='"$S3_BUCKET"' endpoint='"$S3_ENDPOINT"''`

## Chart Configuration Notes
- Secret `logging/loki-s3` is injected via `global.extraEnvFrom` and `singleBinary.extraEnvFrom` into Loki pods.
- Environment expansion is enabled with `-config.expand-env=true` so `${S3_ENDPOINT}`, `${AWS_REGION}`, and `${S3_BUCKET}` in `values.yml` are read from the pod environment.
- S3-compatible storage:
  - `loki.storage.s3.endpoint: ${S3_ENDPOINT}` and `region: ${AWS_REGION}`
  - `loki.storage.object_store.s3.endpoint: ${S3_ENDPOINT}` and `region: ${AWS_REGION}`
  - `s3ForcePathStyle: true` for MinIO and similar providers.
- Bucket names:
  - `loki.storage.bucketNames.{chunks,ruler,admin}: ${S3_BUCKET}`. Ensure `bucket` exists and is stored in Vault.
- Deployment mode:
  - Single-binary enabled (`singleBinary.replicas: 1`), all scalable targets set to `replicas: 0`, `replication_factor: 1`.
- Schema:
  - v13 TSDB schema configured with `from: 2024-04-01`, `index.prefix: index_`, `index.period: 24h`.
- Caches:
  - `chunksCache.enabled: false` and `resultsCache.enabled: false` (can re-enable later).

## Create Buckets (S3-Compatible)
- Using MinIO Client (mc):
  - `export AWS_ACCESS_KEY_ID='<key_id>' AWS_SECRET_ACCESS_KEY='<secret_key>'`
  - `mc alias set minio "${S3_ENDPOINT}" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" --api S3v4`
  - Single bucket for all roles:
    - `mc mb minio/loki-logs || true`
  - Separate buckets example:
    - `mc mb minio/loki-chunks || true`
    - `mc mb minio/loki-ruler || true`
    - `mc mb minio/loki-admin || true`
  - Adjust `bucketNames` in `values.yml` to match what you create.
- Using AWS CLI (for AWS S3):
  - `aws s3api create-bucket --bucket loki-logs --region "$AWS_REGION" --create-bucket-configuration LocationConstraint="$AWS_REGION"`
  - Or create `loki-chunks`, `loki-ruler`, `loki-admin` and update `bucketNames` accordingly.

## Environment Expansion in Config
- Loki is started with `-config.expand-env=true`, so `${S3_ENDPOINT}`, `${AWS_REGION}`, and `${S3_BUCKET}` are resolved from the `loki-s3` Secret environment.

## Internal Access
- Loki service URL inside the cluster: `http://logging-loki.logging.svc.cluster.local:3100`

## Deploy
- Apply the Argo CD application: `kubectl apply -f logging/application.yml`
- Argo CD will sync Helm chart and kustomize resources to namespace `logging`.

## Manual Verification
- `kubectl -n logging get pods`
- Reconcile ExternalSecret: `kubectl -n logging annotate externalsecret loki-s3 reconcile.external-secrets.io/requested-at="$(date -Iseconds)" --overwrite`
- Check ExternalSecret: `kubectl -n logging describe externalsecret loki-s3`
- Confirm Secret: `kubectl -n logging get secret loki-s3 -o json | jq '.data | keys'`

## Troubleshooting
- ExternalSecret errors:
  - Verify Vault policy allows `secret/data/logging/*` and the role includes `logging-s3-read`.
  - Confirm KV v2 is enabled at `secret/`.
- Loki S3 init failures:
  - Ensure bucket and endpoint are set appropriately in Helm values for your provider.

### ExternalSecrets 403 permission denied
- Symptom: `cannot read secret data from Vault ... Code: 403 ... permission denied` when fetching `secret/data/logging/s3`.
- Fix:
  1. Ensure KV v2 and secret exist:
     - `export TOKEN='<vault_token>'`
     - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault secrets enable -path=secret kv-v2 || true'`
     - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault kv get secret/logging/s3 || true'`
  2. (Re)create read policy:
     - `cat > logging-s3-read.hcl <<'EOF'`
     - `path "secret/data/logging/*" { capabilities = ["read"] }`
     - `EOF`
     - `kubectl cp logging-s3-read.hcl vault/vault-0:/tmp/logging-s3-read.hcl -n vault -c vault`
     - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault policy write logging-s3-read /tmp/logging-s3-read.hcl'`
  3. Append policy to ESO role:
     - Inspect current role: `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault read -format=json auth/kubernetes/role/external-secrets'`
     - Update role (preserving existing policies):
       - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' POLICIES=$(vault read -format=json auth/kubernetes/role/external-secrets | jq -r '.data.policies + ["logging-s3-read"] | unique | join(",")') && vault write auth/kubernetes/role/external-secrets bound_service_account_names="external-secrets" bound_service_account_namespaces="external-secrets" policies="'$POLICIES'" ttl="1h"'`
  4. Reconcile and verify:
     - `kubectl -n logging annotate externalsecret loki-s3 reconcile.external-secrets.io/requested-at="$(date -Iseconds)" --overwrite`
     - `kubectl -n logging describe externalsecret loki-s3`
     - `kubectl -n logging get secret loki-s3 -o json | jq '.data | keys'`
