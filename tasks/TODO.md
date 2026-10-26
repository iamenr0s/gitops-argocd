# Task: Deploy trivy-ui to ArgoCD

Deploy [locustbaby/trivy-ui](https://github.com/locustbaby/trivy-ui) as a GitOps-managed ArgoCD Application following established repo patterns.

## Scope

- ArgoCD Application manifest
- Namespace
- Kustomization overlay
- ExternalSecret for kubeconfigs (Vault-backed)
- PVC for cache storage (`kadalu.kadalu-pool-replica3`)
- Updated values.yml (enable persistent cache, reference secret)
- README

## Open Question

⚠️ **Helm chart repository URL needed.** The `values.yml` references image `locustbaby/trivy-ui` but the ArgoCD Application needs a `repoURL` for the Helm chart. Likely options:
- OCI: `oci://ghcr.io/locustbaby/trivy-ui`
- GitHub Pages: `https://locustbaby.github.io/trivy-ui`
- Raw GitHub: `https://github.com/locustbaby/trivy-ui`

**Must confirm chart repo + targetRevision before creating application.yml.**

---

## Plan

### Wave 1 — Core manifests

- [ ] **1. `trivy-ui/namespace.yml`**
  Create namespace `trivy-ui`.
  ```yaml
  apiVersion: v1
  kind: Namespace
  metadata:
    name: trivy-ui
  ```

- [ ] **2. `trivy-ui/kustomization.yml`**
  Standard kustomization referencing namespace + external secret.
  ```yaml
  apiVersion: kustomize.config.k8s.io/v1beta1
  kind: Kustomization
  namespace: trivy-ui
  resources:
    - namespace.yml
    - kubeconfigs.externalsecret.yml
  ```

- [ ] **3. `trivy-ui/kubeconfigs.externalsecret.yml`**
  ExternalSecret pulling kubeconfig files from Vault at `secret/trivy-ui/kubeconfigs`.
  - `sync-wave: "-1"` (before chart sync)
  - `secretStoreRef: vault-backend / ClusterSecretStore`
  - Target secret name: `kubeconfigs` (matches `values.yml: kubeconfigs.secretName`)
  - Data: one entry per cluster (key = cluster name, vault property = kubeconfig content)

- [ ] **4. `trivy-ui/application.yml`**
  Multi-source ArgoCD Application:
  - Source 1: Helm chart (repo URL TBD, chart: `trivy-ui`, targetRevision TBD)
  - Source 2: values ref (`$values/trivy-ui/values.yml`)
  - Source 3: kustomize path (`trivy-ui/`)
  - Destination: `trivy-ui` namespace
  - `sync-wave: "0"`, automated prune + selfHeal, `CreateNamespace=true`

### Wave 2 — Values update

- [ ] **5. `trivy-ui/values.yml`** (update)
  Convert `cache` from emptyDir to persistent volume:
  - If chart supports `persistence:` values → add `persistence.enabled: true`, `storageClass: kadalu.kadalu-pool-replica3`, `size: 2Gi`
  - If chart uses generic `extraVolumes`/`extraVolumeMounts` → replace emptyDir sizeLimit with PVC claim ref

  Also ensure:
  - `kubeconfigs.secretName: kubeconfigs` (already set, confirm not `create: true`)
  - `ingress.tls.secretName: trivy-ui-tls` (cert-manager manages this, no ExternalSecret needed)

### Wave 3 — Documentation + Vault setup

- [ ] **6. `trivy-ui/README.md`**
  Follow influxdb README pattern:
  - App description + structure table
  - Vault setup (seed kubeconfigs, write policy, extend ESO role)
  - Verification commands (pods, externalsecret status, ingress)
  - Troubleshooting section

- [ ] **7. Vault bootstrap commands** (document in README, not applied here)
  ```bash
  # Seed kubeconfigs
  vault kv put secret/trivy-ui/kubeconfigs \
    cluster1="$(cat ~/.kube/config | base64 -w0)"

  # Policy: secret/data/trivy-ui/*
  # Extend ESO role with trivy-ui policy
  ```

---

## Acceptance Criteria

- [ ] `trivy-ui/` directory has: `application.yml`, `namespace.yml`, `kustomization.yml`, `kubeconfigs.externalsecret.yml`, `values.yml`, `README.md`
- [ ] All `.yml` extension (not `.yaml`)
- [ ] ExternalSecret has `sync-wave: "-1"` annotation
- [ ] PVC uses `storageClass: kadalu.kadalu-pool-replica3`
- [ ] `kubeconfigs.secretName: kubeconfigs` and `create: false` in values.yml
- [ ] TLS managed by cert-manager (no ExternalSecret for certs)
- [ ] README covers Vault setup + verification commands

---

## Blocked On

- **Chart repo URL** — need to confirm before writing `application.yml`

---

# Task: VoidAuth ForwardAuth for Traefik

- [x] `traefik/voidauth.middleware.yml` + kustomization entry
- [x] Dashboard IngressRoute uses `voidauth` middleware
- [x] trivy-ui, policy-reporter, monitoring (commented) repointed from Authelia to `traefik-voidauth@kubernetescrd`
- [x] Docs in `voidauth/README.md`, pointer in `traefik/README.md`
- [ ] Configure Proxy Auth domains/groups in VoidAuth UI (manual, before merge)
- [ ] Merge PR, verify 302 on protected hosts

## Review
Authelia was never deployed, so the old middleware reference was dangling. Middleware lives in the `traefik` ns to avoid enabling `allowCrossNamespace`.
