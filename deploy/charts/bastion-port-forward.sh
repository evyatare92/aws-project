#!/usr/bin/env bash
# Starts kubectl port-forward to the main app Service on the bastion loopback.
# Used by "make app-forward" before SSM forwards your laptop to that port.
set -euo pipefail

CLUSTER="${CLUSTER:?CLUSTER is required}"
REGION="${REGION:?REGION is required}"
RELEASE="${RELEASE:-weather-main}"
NAMESPACE="${NAMESPACE:-weather}"
SVC="${SVC:-$RELEASE}"
PF_PORT="${PF_PORT:-8080}"
TARGET_PORT="${TARGET_PORT:-80}"

export PATH="/usr/local/bin:${PATH}"
export KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"

mkdir -p "$(dirname "$KUBECONFIG")"
aws eks update-kubeconfig \
  --name "$CLUSTER" --region "$REGION" --kubeconfig "$KUBECONFIG"

pattern="kubectl port-forward.*${NAMESPACE}/svc/${SVC}"
if pgrep -af "$pattern" >/dev/null 2>&1; then
  echo "Port-forward already running for svc/${SVC} in ${NAMESPACE}"
  exit 0
fi

nohup kubectl port-forward -n "$NAMESPACE" "svc/${SVC}" \
  "${PF_PORT}:${TARGET_PORT}" --address 127.0.0.1 \
  >"/tmp/pf-${NAMESPACE}-${SVC}.log" 2>&1 &
echo "$!" >"/tmp/pf-${NAMESPACE}-${SVC}.pid"

for _ in $(seq 1 30); do
  if ss -ltn 2>/dev/null | grep -q ":${PF_PORT} " || \
     netstat -ltn 2>/dev/null | grep -q ":${PF_PORT} "; then
    echo "Listening on 127.0.0.1:${PF_PORT} -> svc/${SVC}:${TARGET_PORT}"
    exit 0
  fi
  sleep 1
done

echo "Port-forward failed to bind; log:" >&2
tail -n 20 "/tmp/pf-${NAMESPACE}-${SVC}.log" >&2 || true
exit 1
