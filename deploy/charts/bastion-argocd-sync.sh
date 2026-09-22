#!/usr/bin/env bash
# Refreshes the weather-main Application from git.
set -euo pipefail

CLUSTER="${CLUSTER:?CLUSTER is required}"
REGION="${REGION:?REGION is required}"
BUCKET="${BUCKET:?BUCKET is required}"

export PATH="/usr/local/bin:${PATH}"
export KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"

mkdir -p "$(dirname "$KUBECONFIG")"
aws eks update-kubeconfig \
  --name "$CLUSTER" --region "$REGION" --kubeconfig "$KUBECONFIG"

if ! kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
  echo "Argo CD CRDs not installed. Run make argocd." >&2
  exit 2
fi

aws s3 cp "s3://${BUCKET}/argocd/weather-main.yaml" /tmp/weather-main.yaml --region "$REGION"
kubectl apply -f /tmp/weather-main.yaml

if aws s3 cp "s3://${BUCKET}/argocd/repo-secret.yaml" /tmp/repo-secret.yaml --region "$REGION" 2>/dev/null; then
  kubectl apply -f /tmp/repo-secret.yaml
fi

kubectl -n argocd annotate application weather-main \
  argocd.argoproj.io/refresh=hard --overwrite

echo "Application status:"
kubectl -n argocd get application weather-main
kubectl -n argocd get application weather-main \
  -o jsonpath='{.status.sync.status} { .status.health.status}{"\n"}{.status.conditions[*].message}{"\n"}' || true
