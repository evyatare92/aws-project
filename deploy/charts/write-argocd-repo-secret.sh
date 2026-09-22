#!/usr/bin/env bash
# Writes an Argo CD repository Secret for GitHub HTTPS. Runs on the laptop
# during "make argocd-stage". Token is never printed.
set -euo pipefail

out="${1:?output path}"
url="${2:?repo https url}"
token="${GITHUB_TOKEN:-}"
if [ -z "$token" ] && command -v gh >/dev/null 2>&1; then
  token="$(gh auth token 2>/dev/null || true)"
fi
if [ -z "$token" ]; then
  echo "No GITHUB_TOKEN or gh auth; Argo CD will clone $url anonymously"
  rm -f "$out"
  exit 0
fi
umask 077
cat >"$out" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-aws-project
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ${url}
  username: git
  password: ${token}
EOF
echo "Staged git credentials for $url"
