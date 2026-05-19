# Logging (Loki)

Deploys Grafana Loki via Helm in single-binary mode with S3-compatible object storage. S3 credentials sourced from Vault via External Secrets.

## Structure

```
application.yml                # ArgoCD Application — chart + local overlay
values.yml                     # Loki Helm values (single-binary, S3 storage, env injection)
kustomization.yml              # Includes namespace.yml and loki-s3.externalsecret.yml
namespace.yml                  # logging namespace
loki-s3.externalsecret.yml     # ESO — creates Secret loki-s3 with S3 credentials
```

## Vault Setup

Seed credentials before first sync:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/logging/s3 \
    access_key_id='<aws-access-key-id>' \
    secret_access_key='<aws-secret-access-key>' \
    region='<region>' \
    bucket='<bucket-name>' \
    endpoint='<https://s3.amazonaws.com>'
"
```

### Vault Policy

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault policy write logging - <<EOF
path \"secret/data/logging/*\" {
  capabilities = [\"read\"]
}
EOF
"
```

### Extend ESO role

```bash
CURRENT=$(kubectl exec -n vault vault-0 -c vault -- sh -c \
  'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault read -field=policies auth/kubernetes/role/external-secrets' \
  | tr -d '[]' | tr ' ' ',')

kubectl exec -n vault vault-0 -c vault -- sh -c \
  'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault write auth/kubernetes/role/external-secrets \
    bound_service_account_names="external-secrets" \
    bound_service_account_namespaces="external-secrets" \
    policies="'"$CURRENT"',logging" ttl="1h"'
```

## Create S3 Bucket

Using MinIO Client:

```bash
export AWS_ACCESS_KEY_ID='<key_id>'
export AWS_SECRET_ACCESS_KEY='<secret_key>'
mc alias set minio "${S3_ENDPOINT}" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" --api S3v4
mc mb minio/loki-logs || true
```

Using AWS CLI:

```bash
aws s3api create-bucket --bucket loki-logs \
  --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"
```

## Deploy

```bash
kubectl apply -f logging/application.yml
```

## Verification

```bash
# Pods
kubectl -n logging get pods

# ExternalSecret synced
kubectl -n logging describe externalsecret loki-s3

# Force reconcile
kubectl -n logging annotate externalsecret loki-s3 \
  reconcile.external-secrets.io/requested-at="$(date -Iseconds)" --overwrite

# Secret keys present
kubectl -n logging get secret loki-s3 -o json | jq '.data | keys'
```

## Notes

- Internal Loki URL: `http://logging-loki.logging.svc.cluster.local:3100`
- Loki started with `-config.expand-env=true` so `${S3_ENDPOINT}`, `${AWS_REGION}`, and `${S3_BUCKET}` are resolved from pod environment.
- Single-binary mode: `singleBinary.replicas: 1`, all scalable targets at `replicas: 0`, `replication_factor: 1`.
- Schema: v13 TSDB, `from: 2024-04-01`.

## Troubleshooting

- **ExternalSecret 403**: verify Vault policy covers `secret/data/logging/*` and ESO role includes `logging`.
- **S3 init failures**: ensure bucket exists and endpoint/region match `values.yml`.
