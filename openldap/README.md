# OpenLDAP (Helm)

## Overview
- Installs OpenLDAP HA via the community `helm-openldap/openldap-stack-ha` chart, managed by Argo CD.
- Includes PhpLdapAdmin and LTB-Passwd UIs with HTTPS via Traefik and cert-manager.
- Admin and config passwords are sourced from Vault using External Secrets.
- Persistent storage uses the Kadalu storage class.

## Files
- `openldap/application.yml`: Argo CD Application referencing the Helm chart and `openldap/values.yml`.
- `openldap/values.yml`: Helm values (domain, storage, ingresses, TLS settings).
- `openldap/kustomization.yml`: Includes `namespace.yml` and `secrets.externalsecret.yml`.
- `openldap/secrets.externalsecret.yml`: ExternalSecret that materializes Secret `openldap-helm` with required keys.
- `openldap/namespace.yml`: Creates the `openldap` namespace.

## Deploy
- `kubectl apply -f openldap/application.yml`
- Argo CD will create the namespace, materialize secrets from Vault, and install OpenLDAP with UIs and storage.

## Vault
- Path: `secret/openldap/helm`
- Keys:
  - `admin_password` -> becomes Secret key `LDAP_ADMIN_PASSWORD`
  - `config_admin_password` -> becomes Secret key `LDAP_CONFIG_ADMIN_PASSWORD`

## Vault Setup (kubectl-only)
- Variables:
  - `export TOKEN='<vault_token>'`
  - `export ADMIN_PASSWORD='<strong_admin_password>'`
  - `export CONFIG_ADMIN_PASSWORD='<strong_config_password>'`
- Create read policy:
  - `cat > openldap-helm.hcl <<'EOF'`
  - `path "secret/data/openldap/*" { capabilities = ["read"] }`
  - `EOF`
  - `kubectl cp openldap-helm.hcl vault/vault-0:/tmp/openldap-helm.hcl -n vault -c vault`
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault policy write openldap-helm /tmp/openldap-helm.hcl'`
- Bind role to ESO service account (append policy):
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault write auth/kubernetes/role/external-secrets bound_service_account_names="external-secrets" bound_service_account_namespaces="external-secrets" policies="openldap-helm" ttl="1h"'`
- Ensure KV v2 and seed secret:
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault secrets enable -path=secret kv-v2 || true'`
  - `kubectl exec -n vault vault-0 -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='"$TOKEN"' vault kv put secret/openldap/helm admin_password='"$ADMIN_PASSWORD"' config_admin_password='"$CONFIG_ADMIN_PASSWORD"''`

## Access
- PhpLdapAdmin: `https://phpldapadmin.apps.k8s.enros.me`
- LTB-Passwd: `https://ldap-passwd.apps.k8s.enros.me`
- Login DN: `cn=admin,dc=enros,dc=me` (derived from `global.ldapDomain`)
- Password: value of Secret `openldap-helm` key `LDAP_ADMIN_PASSWORD`

### DNS Setup
- Point `phpldapadmin.apps.k8s.enros.me` and `ldap-passwd.apps.k8s.enros.me` to the Traefik LoadBalancer IP.
- Verify Traefik IP: `kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'` or use `externalIPs`:
  - Current config publishes IP `192.168.0.10`.

### Local Access (no DNS)
- `kubectl -n openldap port-forward svc/openldap-phpldapadmin 8080:80`
- Open `http://127.0.0.1:8080`, login with DN `cn=admin,dc=enros,dc=me` and password from Secret.

## Notes
- LDAPS (`636`) is disabled by default. To enable, issue a certificate and set `initTLSSecret.tls_enabled=true` and `initTLSSecret.secret` to a secret containing `tls.key`, `tls.crt`, and `ca.crt` in the `openldap` namespace.
- The chart defaults to multi-master replication; tune `replication.*` in `values.yml` as needed.
- For external clients to reach LDAP (not just the UIs), consider setting `service.type: NodePort` and restricting source ranges.

## Manual Verification
- ExternalSecret:
  - `kubectl -n openldap describe externalsecret openldap-helm`
  - Force reconcile: `kubectl -n openldap annotate externalsecret openldap-helm reconcile.external-secrets.io/requested-at="$(date --iso-8601=seconds)" --overwrite`
- Confirm Secret:
  - `kubectl -n openldap get secret openldap-helm -o jsonpath='{.data.LDAP_ADMIN_PASSWORD}' | base64 -d; echo`
  - `kubectl -n openldap get secret openldap-helm -o jsonpath='{.data.LDAP_CONFIG_ADMIN_PASSWORD}' | base64 -d; echo`
 - Ingress and TLS:
   - `kubectl -n openldap get ingress`
   - Ensure TLS secrets `openldap-phpldapadmin-tls` and `openldap-ltb-passwd-tls` exist.
