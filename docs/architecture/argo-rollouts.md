# Argo Rollouts (canary)

The main app is a **Rollout**, not a Deployment. A new image tag starts a canary. Traffic is split on the Gateway **HTTPRoute** (ALB weighted target groups), not by pod count.

Install the controller **before** Argo CD syncs the chart (the `Rollout` CRD must exist):

```bash
make rollouts
```

Same install pattern as Argo CD: Helm chart pulled on your laptop, staged to S3, bastion installs. Namespace `argo-rollouts`. Dashboard is ClusterIP only; `make rollouts-ui` port-forwards it to **http://127.0.0.1:3100/rollouts** (not the bare `/` path). The dashboard is pinned to the `weather` namespace so it is not stuck on Loading in the empty `argo-rollouts` namespace. The Gateway API traffic plugin is copied from `ghcr.io` into the controller pod.

---

## Canary steps

| Step | Traffic to new version | Gate |
|------|------------------------|------|
| start | 0% (1 canary pod, no ALB weight) | **manual** `make rollouts-promote` |
| 25% | 25 / 75 | **manual** `make rollouts-promote` |
| 50% | 50 / 50 | **automatic after 2 minutes** |
| done | 100% | old ReplicaSet scaled down |

Abort and restore stable: `make rollouts-abort`. Inspect: `make rollouts-status`.

The first cutover (Deployment → Rollout) is **not** a canary; Argo CD prunes the Deployment. After that, image-tag changes follow the table.

CloudFront SPA (`make cdn-sync`) is **not** canaried.

---

## How traffic splits

Two ClusterIP Services: `weather-main` (stable) and `weather-main-canary`. HTTPRoute backends start at weight 100/0. The Rollouts Gateway API plugin rewrites those weights at each `setWeight`. Each Service has its own `TargetGroupConfiguration` (`targetType: ip`).

Argo CD **ignores** HTTPRoute rules/labels and Service selectors so `selfHeal` does not snap weights back to 100/0 mid-canary.

---

## Cluster size

Stable stays 2 replicas. Canary adds **one** extra pod (`canary.replicaCount`). Topology spread is `ScheduleAnyway` so that third pod can land on the two-node group.

---

## Day-to-day

| Command | Effect |
|---------|--------|
| `make rollouts` | Install / upgrade the controller + dashboard |
| `make rollouts-ui` | Dashboard at http://127.0.0.1:3100/rollouts (SSM port-forward) |
| git push of a new `image.tag` | Starts a canary (paused at 0%) |
| `make rollouts-promote` | Advance one manual gate |
| `make rollouts-abort` | Fail the canary, keep stable |
| `make rollouts-status` | `kubectl argo rollouts get` via the bastion |
| `make destroy-rollouts` | Uninstall controller (keeps CRDs) |

`app-forward` still targets Service `weather-main` (stable).
