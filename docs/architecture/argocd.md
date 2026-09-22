# Argo CD

The main app is deployed by **Argo CD** from git (`deploy/charts/main` on `main`). Helm-on-bastion (`make app-helm-direct`) remains a fallback if Argo is not installed.

Argo CD runs **in the cluster** (`namespace argocd`). The API is private, so the UI is `make argocd-ui` (SSM port-forward to `localhost:8081`), not a public ALB.

---

## Install

```bash
make argocd
```

That pulls the official Helm chart on your laptop, stages it to the artifacts bucket, and installs from the bastion (same pattern as LBC). If `gh auth` or `GITHUB_TOKEN` is set, a repository Secret is created so Argo can clone a **private** GitHub repo. Public repos work without a token.

Printed once: admin password from `argocd-initial-admin-secret`. User is `admin`.

---

## Day-to-day

| Command | Effect |
|---------|--------|
| `make app-push` | Build and push the main image |
| `make charts-version` | Write image tag + CFN URLs into `deploy/charts/main/values.yaml` |
| **git commit and push** those values | Argo auto-syncs `weather-main` |
| `make argocd-sync` | Re-apply the Application CR and hard-refresh from git |
| `make app-deploy` | push + charts-stage + Argo sync (or Helm fallback) + `cdn-sync` |
| `make argocd-ui` | UI at http://127.0.0.1:8081 |
| `make app-helm-direct` | Old path: Helm upgrade from S3 on the bastion |

Auto-sync is on (`prune` + `selfHeal`). The cluster follows **origin/main**, not uncommitted local files. New image tags start an Argo Rollouts **canary** (see [argo-rollouts.md](argo-rollouts.md)); `make rollouts-promote` is the manual gate.

---

## Application

Manifest: `deploy/argocd/weather-main.yaml`. Release name `weather-main`, namespace `weather`, Helm path `deploy/charts/main`. `ServerSideApply` so Argo can adopt the existing Helm release.

Override repo: `make argocd GIT_REPO=https://github.com/you/aws-project.git GIT_REVISION=main`.
