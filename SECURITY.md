# Security Policy

## Supported Versions

This repository tracks a single live environment — only the `main` branch (what's currently deployed) is supported.

| Branch | Supported |
| ------- | --------- |
| `main` | ✅ |
| Any other branch | ❌ |

## Reporting a Vulnerability

Please **do not** open a public issue for security vulnerabilities.

Instead, report them privately via [GitHub private vulnerability reporting](https://github.com/iamenr0s/gitops-argocd/security/advisories/new).

Include a description of the issue, the affected app/manifest, and reproduction steps if relevant. Note that this repository contains no secrets — credentials live in Vault and are pulled in at sync time via `ExternalSecret` resources — but manifest misconfigurations (overly broad RBAC, exposed services, missing NetworkPolicies, etc.) are in scope.

You can expect an initial response within 7 days. Once the issue is confirmed, a fix will be released as soon as practical and you will be credited unless you prefer otherwise.
