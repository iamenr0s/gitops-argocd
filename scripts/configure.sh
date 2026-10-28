#!/usr/bin/env bash
# Customise this repository for your environment.
#
# Argo CD cannot template plain manifests, so the environment-specific values
# ship as obvious placeholders (example.com, example-org, ...). This script
# rewrites them in place. Review `git diff` afterwards, then commit and push.
#
# Usage:
#   DOMAIN=mycorp.net REPO_URL=https://github.com/me/gitops-argocd.git \
#   ACME_EMAIL=ops@mycorp.net ./scripts/configure.sh
#
# Variables (all optional; unset ones are left untouched):
#   DOMAIN         base domain                         (default placeholder: example.com)
#   APPS_SUBDOMAIN wildcard apps zone prefix           (default placeholder: apps -> apps.example.com)
#   ACME_EMAIL     Let's Encrypt registration email    (default placeholder: admin@example.com)
#   REPO_URL       this repo's git URL                 (default placeholder: https://github.com/example-org/gitops-argocd.git)
#   HARDENING_REPO_URL  k8s-hardening-cis fork URL     (default placeholder: https://github.com/example-org/k8s-hardening-cis.git)
#   IMAGE_ORG      registry namespace for custom images (default placeholder: example-org)
#   STORAGE_CLASS  StorageClass used by stateful apps  (default: kadalu.kadalu-pool-replica3)
#   TRAEFIK_LB_IP  Cilium LB-IPAM address for Traefik  (default placeholder: 192.0.2.10)
#   LDAP_BASE_DN   OpenLDAP base DN                    (default placeholder: dc=example,dc=com; derived from DOMAIN if unset)
set -euo pipefail
cd "$(dirname "$0")/.."

files=$(git ls-files '*.yml' '*.yaml' '*.md' '*.json' ':!:LICENSE' ':!:scripts/*')

# replace <old> <new>: literal (non-regex) global replace across tracked files
replace() {
  local old=$1 new=$2
  [ -n "$new" ] && [ "$old" != "$new" ] || return 0
  # shellcheck disable=SC2086
  OLD="$old" NEW="$new" perl -pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' $files
}

# Order matters: most specific strings first.
if [ -n "${REPO_URL:-}" ]; then
  replace "https://github.com/example-org/gitops-argocd.git" "$REPO_URL"
  replace "https://github.com/example-org/gitops-argocd" "${REPO_URL%.git}"
fi
if [ -n "${HARDENING_REPO_URL:-}" ]; then
  replace "https://github.com/example-org/k8s-hardening-cis.git" "$HARDENING_REPO_URL"
  replace "https://github.com/example-org/k8s-hardening-cis" "${HARDENING_REPO_URL%.git}"
fi
if [ -n "${IMAGE_ORG:-}" ]; then
  # custom image repositories only (not github.com/example-org/ URLs)
  # shellcheck disable=SC2086
  NEW="$IMAGE_ORG/" perl -pi -e 's{(?<!github\.com/)example-org/}{$ENV{NEW}}g' $files
fi
[ -z "${ACME_EMAIL:-}" ] || replace "admin@example.com" "$ACME_EMAIL"
[ -z "${TRAEFIK_LB_IP:-}" ] || replace '"192.0.2.10"' "\"$TRAEFIK_LB_IP\""
[ -z "${STORAGE_CLASS:-}" ] || replace "kadalu.kadalu-pool-replica3" "$STORAGE_CLASS"

if [ -n "${DOMAIN:-}" ]; then
  if [ -z "${LDAP_BASE_DN:-}" ]; then
    LDAP_BASE_DN=$(awk -F. '{for(i=1;i<=NF;i++) printf "%sdc=%s", (i>1?",":""), $i}' <<<"$DOMAIN")
  fi
  replace "dc=example,dc=com" "$LDAP_BASE_DN"
  apps="${APPS_SUBDOMAIN:-apps}.$DOMAIN"
  replace "apps.example.com" "$apps"
  replace "internal.example.com" "internal.$DOMAIN"
  replace "ldapDomain: example.com" "ldapDomain: $DOMAIN"
  replace "    - example.com" "    - $DOMAIN"   # traefik/certificate.yml apex SAN
fi

echo "Done. Review with: git diff"
