# OpenLDAP

Deploys OpenLDAP HA via the `helm-openldap/openldap-stack-ha` chart, managed by Argo CD. Includes PhpLdapAdmin and LTB-Passwd UIs with HTTPS via Traefik. Admin credentials sourced from Vault via External Secrets; persistent storage on Kadalu.

## Structure

```
application.yml              # ArgoCD Application — chart + values.yml
values.yml                   # Helm values (domain, storage, ingresses, TLS)
kustomization.yml            # Includes namespace.yml and secrets.externalsecret.yml
secrets.externalsecret.yml   # ESO — creates Secret openldap-helm from Vault
namespace.yml                # openldap namespace
```

## Vault Setup

Seed credentials before first sync:

```bash
TOKEN="$(kubectl -n vault get secret vault-root-token -o jsonpath='{.data.token}' | base64 -d)"

kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault kv put secret/openldap/helm \
    admin_password='<strong-admin-password>' \
    config_admin_password='<strong-config-password>'
"
```

### Vault Policy

```bash
kubectl exec -n vault vault-0 -c vault -- sh -c "
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$TOKEN \
  vault policy write openldap - <<EOF
path \"secret/data/openldap/*\" {
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
    policies="'"$CURRENT"',openldap" ttl="1h"'
```

## Deploy

```bash
kubectl apply -f openldap/application.yml
```

## Verification

```bash
# ExternalSecret synced
kubectl -n openldap describe externalsecret openldap-helm

# Force reconcile
kubectl -n openldap annotate externalsecret openldap-helm \
  reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite

# Decode credentials
kubectl -n openldap get secret openldap-helm \
  -o jsonpath='{.data.LDAP_ADMIN_PASSWORD}' | base64 -d; echo
kubectl -n openldap get secret openldap-helm \
  -o jsonpath='{.data.LDAP_CONFIG_ADMIN_PASSWORD}' | base64 -d; echo

# Ingress and TLS
kubectl -n openldap get ingress

# Local port-forward (no DNS)
kubectl -n openldap port-forward svc/openldap-phpldapadmin 8080:80
# Open http://127.0.0.1:8080, login with cn=admin,dc=enros,dc=me
```

## Notes

- PhpLdapAdmin: `https://phpldapadmin.apps.k8s.enros.me`
- LTB-Passwd: `https://ldap-passwd.apps.k8s.enros.me`
- Login DN: `cn=admin,dc=enros,dc=me`
- Traefik LoadBalancer IP: `192.168.0.10`
- LDAPS (636) disabled by default; enable via `initTLSSecret.tls_enabled=true`.

## Troubleshooting

- **Secret not materializing**: confirm Vault policy covers `secret/data/openldap/*` and ESO role is updated.
- **LDAP bind fails**: verify admin password in Secret matches Vault; check pod logs: `kubectl -n openldap logs statefulset/openldap`.
- **PhpLdapAdmin unreachable**: check ingress, TLS cert status, and DNS.
