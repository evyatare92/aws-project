#!/usr/bin/env bash
# Promote / abort / status for the weather-main Rollout.
# ACTION=promote|abort|status  (default status)
set -euo pipefail

CLUSTER="${CLUSTER:?CLUSTER is required}"
REGION="${REGION:?REGION is required}"
BUCKET="${BUCKET:?BUCKET is required}"
NAMESPACE="${NAMESPACE:-weather}"
RELEASE="${RELEASE:-weather-main}"
ACTION="${ACTION:-status}"

export PATH="/usr/local/bin:${PATH}"
export KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"

mkdir -p "$(dirname "$KUBECONFIG")"
aws eks update-kubeconfig \
  --name "$CLUSTER" --region "$REGION" --kubeconfig "$KUBECONFIG"

if [ ! -x /usr/local/bin/kubectl-argo-rollouts ]; then
  aws s3 cp "s3://${BUCKET}/argo-rollouts/kubectl-argo-rollouts" \
    /usr/local/bin/kubectl-argo-rollouts --region "$REGION"
  chmod 0755 /usr/local/bin/kubectl-argo-rollouts
fi

if ! kubectl get crd rollouts.argoproj.io >/dev/null 2>&1; then
  echo "Argo Rollouts CRDs not installed. Run make rollouts." >&2
  exit 2
fi

case "$ACTION" in
  promote)
    kubectl argo rollouts promote "$RELEASE" -n "$NAMESPACE"
    ;;
  abort)
    kubectl argo rollouts abort "$RELEASE" -n "$NAMESPACE"
    ;;
  status)
    ;;
  *)
    echo "Unknown ACTION=${ACTION} (promote|abort|status)" >&2
    exit 1
    ;;
esac

kubectl argo rollouts get rollout "$RELEASE" -n "$NAMESPACE"
