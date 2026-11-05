---
name: Bug report
about: Report a problem with an app or manifest in this repo
title: ''
labels: bug
assignees: ''
---

## Describe the bug

A clear and concise description of what the bug is.

## Affected app

Which app directory is this about (e.g. `monitoring`, `influxdb`, `harbor`)?

## To reproduce

Steps to reproduce, and the relevant manifest snippet if applicable:

```yaml
# application.yml / values.yml excerpt
```

## Expected behavior

What you expected to happen.

## Actual behavior

What actually happened. Include relevant output:

```
kubectl -n argocd get application <name> -o yaml
# or: argocd app get <name>
# or: kubectl -n <namespace> get pods / describe pod ...
```

## Environment

- Argo CD sync status (`Synced`/`OutOfSync`) and health status:
- Namespace:
- Approximate time the issue started:

## Additional context

Anything else that might help (recent related PRs, Vault reseed events, cluster maintenance, etc.).
