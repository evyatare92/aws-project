# Architecture overview

The Weather Board SPA is on **CloudFront** (S3 origin). Live forecasts still run on **Amazon EKS**: CloudFront path `/api/*` is a second origin to the Gateway ALB. Each city uses a different backend integration: **ECS + Cloud Map**, **private API Gateway + agent Lambda**, **AgentCore Runtime**, and **SQS + worker Lambda + DynamoDB poll**.

Everything runs in a **private VPC** (`10.0.0.0/16`) except the public edge. There is no VPN and no public Kubernetes API. Operators reach the cluster through a **bastion** (SSM Session Manager). The UI is **`make cdn`**: CloudFront + WAF (your IP) serving the SPA from S3 and proxying `/api/*` to the Gateway ALB. The ALB only accepts CloudFront. `make app-forward` still reaches pods without the CDN.

---

## System context

```mermaid
flowchart TB
  subgraph Internet["Internet (optional)"]
    UserPC["Your browser"]
    OpenMeteo["Open-Meteo API"]
    Anthropic["Anthropic API"]
  end

  subgraph PublicEdge["Public edge (make cdn)"]
    CF["CloudFront CDN + WAF"]
    S3Front["S3 SPA"]
    ALB["Internet-facing ALB\nGateway API"]
  end

  subgraph VPC["VPC 10.0.0.0/16"]
    Bastion["Bastion EC2\nSSM only"]
    EKS["EKS cluster\nprivate API"]
    ECS["ECS Fargate\nweather service"]
    AgentCore["AgentCore Runtime\nTel Aviv agent"]
    LambdaVPC["Lambda ENIs"]
    VPCE["VPC endpoints\nAWS APIs"]
    NAT["NAT Gateway\none per AZ"]
  end

  UserPC -->|"HTTPS\nWAF IP allowlist"| CF
  CF -->|"static OAC"| S3Front
  CF -->|"/api/* HTTP"| ALB
  UserPC -->|"SSM Session Manager"| Bastion
  ALB --> EKS
  Bastion --> EKS

  subgraph MainApp["Namespace weather"]
    Pods["weather-main pods\nClusterIP :80 → :8080"]
  end

  EKS --> Pods
  Pods -->|"HTTP Cloud Map"| ECS
  Pods -->|"HTTPS execute-api\n(via VPC endpoint)"| LambdaVPC
  Pods -->|"InvokeAgentRuntime\n(via VPC endpoint)"| AgentCore
  Pods -->|"SQS + DynamoDB\n(IRSA)"| VPCE

  ECS --> NAT --> OpenMeteo
  AgentCore --> NAT
  NAT --> OpenMeteo
  NAT --> Anthropic
  LambdaVPC --> NAT
  Pods --> NAT
```

---

## CloudFormation stacks (logical order)

Stacks are named `{ProjectName}-{Environment}-*` (default `aws-project-dev-*). Exports wire stacks together.

| Order | Makefile target | Stack / template | Role |
|------:|-------------------|------------------|------|
| 1 | `bootstrap` | `infra/00-bootstrap/artifacts.yaml` | S3 artifacts bucket (Helm charts, Lambda zips, bastion tools) |
| 2 | `registry` | `infra/15-registry/ecr.yaml` | ECR repos for `main`, `weather`, and `agentcore` images |
| 3 | `network` | `infra/10-network/vpc.yaml` | VPC, app/data/endpoint subnets, route tables (no IGW yet) |
| 4 | `nat` | `infra/10-network/nat.yaml` | IGW, **one NAT per AZ**, public subnets for Gateway ALB |
| 5 | `endpoints` | `infra/10-network/endpoints.yaml` | S3/DynamoDB gateway + interface endpoints (SSM, ECR, EKS, …); default **multi-AZ** |
| 6 | `eks` | `infra/20-eks/cluster.yaml` | Private EKS 1.36, node group (min 2 nodes), OIDC for IRSA |
| 7 | `ecs` | `infra/30-ecs/cluster.yaml` | ECS cluster + task roles |
| 8 | `ecs-weather` | `infra/31-ecs/weather-service.yaml` | Fargate weather API (2 tasks, AZ spread) + Cloud Map |
| 9 | `lambda` | `infra/40-lambda/functions.yaml` | Agent + SQS Lambdas, private API Gateway, SQS, DynamoDB, **MainAppRole** (IRSA) |
| 10 | `agentcore` | `infra/41-agentcore/runtime.yaml` | Bedrock AgentCore Runtime (Tel Aviv Strands agent, VPC) |
| 11 | `bastion` | `infra/50-bastion/bastion.yaml` | SSM bastion, EKS access entry |

**Not in `make all` (opt-in):**

| Target | Template | Role |
|--------|----------|------|
| `lbc-iam` / `lbc` | `infra/61-lbc/iam.yaml` + Helm | IRSA for AWS Load Balancer Controller |
| `alb` | Helm (main chart Gateway) | Internet-facing ALB + Gateway/HTTPRoute (`sourceRanges` until CDN) |
| `cdn-waf` | `infra/62-cdn/waf.yaml` (us-east-1) | CloudFront-scope WAF IP allowlist |
| `cdn` | `infra/62-cdn/frontend.yaml` + Helm + `cdn-sync` | Private S3 (OAC) + CloudFront; `/api/*` → ALB; ALB SG = CloudFront prefix list |

Legacy **`infra/60-alb/alb.yaml`** (CloudFormation ALB + NodePort) is kept for teardown only; **Gateway** is the supported public path.

---

## Application components

| Path | Runtime | Purpose |
|------|---------|---------|
| `app/main/web/` | S3 → CloudFront | Weather Board UI |
| `app/main/` | Docker → EKS | `/api/live/weather/{city}` router (static files still bundled for `app-forward`) |
| `app/weather/` | Docker → ECS Fargate | Open-Meteo proxy for **New York** |
| `app/agent/` | Lambda (HTTP) | Strands + Claude Sonnet 4.5 for **Barcelona** |
| `app/agentcore/` | Docker (arm64) → AgentCore Runtime | Strands + Claude Sonnet 4.5 for **Tel Aviv** |
| `app/sqs-weather/` | Lambda (SQS) | Open-Meteo for **Bangkok** / **Tokyo**; results via DynamoDB |

Helm chart: `deploy/charts/main/` (release `weather-main`, namespace `weather`).

---

## Deploy and release flow

```mermaid
sequenceDiagram
  participant Dev as Developer PC
  participant ECR as ECR
  participant Git as GitHub
  participant Argo as Argo CD
  participant EKS as EKS API

  Dev->>ECR: make app-push
  Dev->>Git: commit values and chart
  Git->>Argo: auto-sync weather-main
  Argo->>EKS: Helm apply ServerSideApply
```

- **Image tags** come from `app/main/.version` (not `latest` in cluster).
- **Chart values** pull CloudFormation exports (agent URL, SQS URL, DynamoDB table, MainApp IRSA ARN, Gateway subnets, and after CDN the CloudFront ALB security group). Commit those values so Argo sees them.
- **EKS API is private**; Argo CD runs in-cluster. `kubectl` / Helm fallback run on the bastion.

See [argocd.md](argocd.md).

Public URL after `make cdn`: `https://{CloudFront domain}` (WAF allows `CLIENT_CIDR`). The Gateway ALB is only reachable from CloudFront.

Local dev tunnel without CDN: `make app-forward` starts `kubectl port-forward` on the bastion, then SSM forwards `localhost:8080`.

---

## City → backend map

| City | Backend key | Integration |
|------|-------------|-------------|
| New York | `ecs` | HTTP to `http://weather.{stack}.local:8080/weather/new-york` |
| Barcelona | `agent` | GET `{AgentApiUrl}/weather/barcelona` (private API Gateway) |
| Tel Aviv | `agentcore` | `InvokeAgentRuntime` on AgentCore Runtime ARN |
| Bangkok, Tokyo | `sqs` | SQS message + poll DynamoDB by `requestId` |

Static placeholder data for all cities: `GET /api/weather` → bundled `web/data/weather.json`.

See [weather-backends.md](weather-backends.md) for step-by-step flows.

---

## Related docs

- [Network and routing](network-and-routing.md)
- [CloudFront, S3, and WAF](cdn-and-waf.md)
- [Security groups](security-groups.md)
- [Argo CD](argocd.md)
- [Kubernetes and Gateway](kubernetes-and-gateway.md)
- [Weather backends](weather-backends.md)
- [IAM and access](iam-and-access.md)
