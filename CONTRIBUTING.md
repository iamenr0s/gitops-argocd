# Contributing

Thanks for taking the time to contribute to `gitops-argocd`!

## Getting started

1. Fork the repository and create your branch from `main`.
2. Install the tools you'll need locally: `kubectl`, `kustomize` (or `kubectl kustomize`), and optionally [`kubeconform`](https://github.com/yannh/kubeconform) and [`yamllint`](https://github.com/adrienverge/yamllint) to run the same checks CI does.

## Making changes

- Keep changes small and focused — one app or concern per pull request.
- Follow the existing layout described in `CLAUDE.md` (`application.yml`, `values.yml`, `kustomization.yml`, `*.externalsecret.yml` per app).
- Use `.yml`, not `.yaml` — CI rejects the latter.
- Never commit secrets. Credentials live in Vault and surface via `ExternalSecret` resources referencing `ClusterSecretStore vault-backend`.
- Editing an app's `application.yml` (chart version, sync policy, source)? No extra step needed — it's picked up automatically by `bootstrap/application.yml`'s glob once merged to `main`. Only a nonstandard filename needs its pattern added there.

## Testing

Before opening a pull request, make sure the same checks CI runs pass locally:

```bash
yamllint .

# Render every app's kustomization
for d in $(find . -name kustomization.yml -exec dirname {} \;); do
  kubectl kustomize --load-restrictor LoadRestrictionsNone "$d" > /dev/null
done

# Optional: schema-check the rendered output
kubeconform -summary -ignore-missing-schemas -strict=false <(kubectl kustomize --load-restrictor LoadRestrictionsNone <app-dir>)
```

This repo has no build step and no application test suite — the "deployment" is a `git push` to `main`, so getting the manifests right matters more than usual.

## Submitting a pull request

1. Ensure the checks above pass locally.
2. Fill in the pull request template.
3. A maintainer will review your PR; CI must be green before merge.

## Reporting bugs and requesting features

Use the issue templates — they ask for the details (affected app, Argo CD sync/health status) needed to reproduce a problem.

## Code of Conduct

This project follows the [Contributor Covenant Code of Conduct](CODE_OF_CONDUCT.md). By participating you agree to abide by it.
