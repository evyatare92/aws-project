#!/usr/bin/env bash
# Installs Argo Rollouts (canary controller) and the kubectl plugin.
#
# Runs on the bastion via "make rollouts" (SSM). Images pull through NAT.
set -euo pipefail

BUCKET="${BUCKET:?BUCKET is required}"
CLUSTER="${CLUSTER:?CLUSTER is required}"
REGION="${REGION:?REGION is required}"
ROLLOUTS_DIR="/tmp/argo-rollouts"

export PATH="/usr/local/bin:${PATH}"
export KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"

mkdir -p "$(dirname "$KUBECONFIG")"
aws eks update-kubeconfig \
  --name "$CLUSTER" --region "$REGION" --kubeconfig "$KUBECONFIG"

rm -rf "$ROLLOUTS_DIR"
aws s3 cp --recursive "s3://${BUCKET}/argo-rollouts" "$ROLLOUTS_DIR" --region "$REGION"

if [ ! -d "${ROLLOUTS_DIR}/chart" ]; then
  echo "Missing staged Argo Rollouts chart under s3://${BUCKET}/argo-rollouts/chart" >&2
  exit 1
fi

if [ -f "${ROLLOUTS_DIR}/kubectl-argo-rollouts" ]; then
  install -m 0755 "${ROLLOUTS_DIR}/kubectl-argo-rollouts" /usr/local/bin/kubectl-argo-rollouts
fi

echo "Installing Argo Rollouts"
helm upgrade --install argo-rollouts "${ROLLOUTS_DIR}/chart" \
  --namespace argo-rollouts --create-namespace \
  --values "${ROLLOUTS_DIR}/values.yaml" \
  --wait --timeout 10m

kubectl -n argo-rollouts rollout status deploy/argo-rollouts --timeout=180s
kubectl -n argo-rollouts get pods
kubectl get crd rollouts.argoproj.io
echo "Argo Rollouts installed. Promote: make rollouts-promote"
