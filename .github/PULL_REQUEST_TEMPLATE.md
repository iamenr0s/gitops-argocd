# Pull Request

## Description

What does this PR change and why?

## Type of change

- [ ] New app / Argo CD Application
- [ ] Change to an existing app (chart version, values, sync policy, ...)
- [ ] Secret/ExternalSecret wiring
- [ ] Documentation
- [ ] CI / tooling

## Checklist

- [ ] Files use `.yml`, not `.yaml`
- [ ] `yamllint .` passes
- [ ] `kubectl kustomize` renders cleanly for any `kustomization.yml` touched
- [ ] No secrets committed — credentials go in Vault via `ExternalSecret`
- [ ] New `application.yml` (or `*-crds.yml`/`*-controller.yml`) is covered by `bootstrap/application.yml`'s include patterns (CI checks this)
- [ ] Follows the [contributing guidelines](../CONTRIBUTING.md)

## Related issues

Closes #
