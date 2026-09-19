#!/usr/bin/env bash
# Pulls the staged chart from S3 and rolls it out on the cluster.
#
# Runs on the bastion, launched by "make app-deploy" over SSM Run Command, not
# from your PC: the EKS API is private and only reachable from inside the VPC.
set -euo pipefail

BUCKET="${BUCKET:?BUCKET is required}"
CLUSTER="${CLUSTER:?CLUSTER is required}"
REGION="${REGION:?REGION is required}"
RELEASE="${RELEASE:-weather-main}"
NAMESPACE="${NAMESPACE:-weather}"

# kubectl and helm were staged here by "make bastion-tools"; Run Command starts
# with a minimal environment, so neither PATH nor HOME can be relied on.
export PATH="/usr/local/bin:${PATH}"
export KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"

CHART_DIR="/tmp/${RELEASE}"

mkdir -p "$(dirname "$KUBECONFIG")"
aws eks update-kubeconfig \
  --name "$CLUSTER" --region "$REGION" --kubeconfig "$KUBECONFIG"

rm -rf "$CHART_DIR"
aws s3 cp --recursive "s3://${BUCKET}/charts/main" "$CHART_DIR" --region "$REGION"

helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" --create-namespace \
  --wait --timeout 5m

# Selected by label rather than name: the chart's fullname depends on how the
# release and chart names line up.
deployment="$(kubectl get deployment -n "$NAMESPACE" \
  -l "app.kubernetes.io/instance=${RELEASE}" -o name | head -n 1)"

if [ -n "$deployment" ]; then
  # values.yaml pins the mutable "latest" tag, so a re-push of the same tag
  # needs an explicit restart to be picked up.
  kubectl rollout restart "$deployment" -n "$NAMESPACE"
  kubectl rollout status "$deployment" -n "$NAMESPACE" --timeout=180s
else
  echo "WARNING: no deployment found for release ${RELEASE}" >&2
fi

kubectl get pods,svc -n "$NAMESPACE" -l "app.kubernetes.io/instance=${RELEASE}"
