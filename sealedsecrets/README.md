# Sealed Secrets

Deploys the Bitnami Sealed Secrets controller via Helm. Enables encrypting Kubernetes secrets for safe storage in Git.

## Structure

```
application.yml   # ArgoCD Application — sealed-secrets Helm chart
values.yml        # Helm values (fullnameOverride: sealed-secrets-controller)
```

## Deploy

Commit and push — Argo CD will sync the controller to namespace `sealed-secrets`.

## Usage

Encrypt a secret for use in the repo:

```bash
kubeseal \
  --controller-name sealed-secrets-controller \
  --controller-namespace sealed-secrets \
  -n <namespace> \
  < secret.yaml > secret.sealed.yaml
```

Commit `secret.sealed.yaml` to the repo. Argo CD applies it and the controller decrypts it on the cluster.

## Verification

```bash
# Controller pod
kubectl -n sealed-secrets get pods

# Seal and apply a test secret
echo '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"test","namespace":"default"},"stringData":{"key":"value"}}' \
  | kubeseal --controller-name sealed-secrets-controller \
             --controller-namespace sealed-secrets \
  > /tmp/test-sealed.yaml
kubectl apply -f /tmp/test-sealed.yaml
kubectl -n default get secret test -o yaml
kubectl delete -f /tmp/test-sealed.yaml
kubectl -n default delete secret test
```

## Notes

- `fullnameOverride: sealed-secrets-controller` is set so `kubeseal` can locate the controller.
- Controller name and namespace must match the `--controller-*` flags in `kubeseal`.

## Troubleshooting

- **Controller name mismatch**: ensure `kubeseal` flags match the `fullnameOverride` in `values.yml` and the namespace.
