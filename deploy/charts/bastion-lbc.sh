#!/usr/bin/env bash
# Installs Gateway API CRDs and the AWS Load Balancer Controller.
#
# Runs on the bastion, launched by "make lbc" over SSM Run Command. The EKS
# API is private; the controller image is pulled through NAT.
set -euo pipefail

BUCKET="${BUCKET:?BUCKET is required}"
CLUSTER="${CLUSTER:?CLUSTER is required}"
REGION="${REGION:?REGION is required}"
LBC_DIR="/tmp/aws-load-balancer-controller"

export PATH="/usr/local/bin:${PATH}"
export KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"

mkdir -p "$(dirname "$KUBECONFIG")"
aws eks update-kubeconfig \
  --name "$CLUSTER" --region "$REGION" --kubeconfig "$KUBECONFIG"

rm -rf "$LBC_DIR"
aws s3 cp --recursive "s3://${BUCKET}/lbc" "$LBC_DIR" --region "$REGION"

if [ ! -d "${LBC_DIR}/chart" ]; then
  echo "Missing staged LBC chart under s3://${BUCKET}/lbc/chart" >&2
  exit 1
fi

echo "Applying Gateway API CRDs"
kubectl apply --server-side --force-conflicts -f "${LBC_DIR}/gateway-api-crds.yaml"

echo "Installing AWS Load Balancer Controller"
helm upgrade --install aws-load-balancer-controller "${LBC_DIR}/chart" \
  --namespace kube-system \
  --values "${LBC_DIR}/values.yaml" \
  --wait --timeout 10m

kubectl -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=180s
kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-load-balancer-controller
