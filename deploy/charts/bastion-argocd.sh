#!/usr/bin/env bash
# Installs Argo CD and the weather-main Application.
#
# Runs on the bastion via "make argocd" (SSM). Images pull through NAT.
set -euo pipefail

BUCKET="${BUCKET:?BUCKET is required}"
CLUSTER="${CLUSTER:?CLUSTER is required}"
REGION="${REGION:?REGION is required}"
ARGO_DIR="/tmp/argocd"

export PATH="/usr/local/bin:${PATH}"
export KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"

mkdir -p "$(dirname "$KUBECONFIG")"
aws eks update-kubeconfig \
  --name "$CLUSTER" --region "$REGION" --kubeconfig "$KUBECONFIG"

rm -rf "$ARGO_DIR"
aws s3 cp --recursive "s3://${BUCKET}/argocd" "$ARGO_DIR" --region "$REGION"

if [ ! -d "${ARGO_DIR}/chart" ]; then
  echo "Missing staged Argo CD chart under s3://${BUCKET}/argocd/chart" >&2
  exit 1
fi

echo "Installing Argo CD"
helm upgrade --install argocd "${ARGO_DIR}/chart" \
  --namespace argocd --create-namespace \
  --values "${ARGO_DIR}/values.yaml" \
  --wait --timeout 10m

kubectl -n argocd rollout status deploy/argocd-server --timeout=180s
kubectl -n argocd get pods

if [ -f "${ARGO_DIR}/repo-secret.yaml" ]; then
  echo "Applying git repository credentials"
  kubectl apply -f "${ARGO_DIR}/repo-secret.yaml"
fi

if [ -f "${ARGO_DIR}/weather-main.yaml" ]; then
  echo "Applying weather-main Application"
  kubectl apply -f "${ARGO_DIR}/weather-main.yaml"
fi

kubectl -n argocd get application weather-main || true
pw="$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
if [ -n "$pw" ]; then
  echo "Argo CD admin password (user admin): $pw"
  echo "UI: make argocd-ui  (http://localhost:8081)"
fi
