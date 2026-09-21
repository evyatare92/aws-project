# Network and routing

The VPC is designed as a **private application network** with **controlled egress** and **no inbound internet** except what you explicitly add (NAT for outbound, Gateway ALB for the web app).

Default CIDR: **`10.0.0.0/16`** (`infra/10-network/vpc.yaml`).

---

## Subnet layout

For `10.0.0.0/16`, subnets are carved from fixed offsets:

| Tier | CIDR blocks (×3 AZs) | Use |
|------|----------------------|-----|
| **App** | `10.0.0.0/19`, `10.0.32.0/19`, `10.0.64.0/19` | EKS nodes/pods, ECS tasks, Lambda ENIs, bastion |
| **Data** | `10.0.96.0/24` … `10.0.98.0/24` | Reserved for data-tier workloads (egress-free route table) |
| **Endpoints** | `10.0.100.0/24` … `10.0.102.0/24` | Interface VPC endpoint ENIs |
| **Public (NAT stack)** | `10.0.104.0/24` (a), `10.0.105.0/24` (b), `10.0.106.0/24` (c) | NAT gateway, internet-facing ALB subnets |

App subnets are tagged:

- `kubernetes.io/role/internal-elb=1` — internal load balancers (if used)
- `kubernetes.io/cluster/{cluster-name}=shared` — cluster ownership for LBC/EKS

Public subnets (NAT stack) are tagged:

- `kubernetes.io/role/elb=1` — internet-facing ALBs (Gateway)
- Same cluster shared tag

---

## Route tables

```mermaid
flowchart LR
  subgraph AppRT["App route tables (per AZ)"]
    AppA["app-a RT"]
    AppB["app-b RT"]
    AppC["app-c RT"]
  end

  subgraph IsolatedRT["Isolated RT"]
    Data["data subnets"]
    EP["endpoint subnets"]
  end

  subgraph PublicRT["NAT public RT"]
    PubA["pub subnet a"]
    PubB["pub subnet b"]
    PubC["pub subnet c"]
  end

  IGW["Internet Gateway"]
  NATA["NAT GW a"]
  NATB["NAT GW b"]
  NATC["NAT GW c"]

  AppA -->|"0.0.0.0/0"| NATA
  AppB --> NATB
  AppC --> NATC
  NATA --> IGW
  NATB --> IGW
  NATC --> IGW
  NATA --- PubA
  NATB --- PubB
  NATC --- PubC

  PubA --> IGW
  PubB --> IGW
  PubC --> IGW

  Data -->|"local only"| Data
  EP -->|"local + VPCE"| EP
```

**Before `make nat`:** app route tables have **no default route** to the internet. Workloads reach AWS APIs via **VPC endpoints** only.

**After `make nat`:** each app route table uses the **NAT Gateway in the same AZ** (`AppRouteNatA/B/C` → `NatGateway` / `NatGatewayB` / `NatGatewayC` in `infra/10-network/nat.yaml`). Loss of one AZ does not force all private egress through a NAT in a failed zone. That enables:

- ECS Fargate and Lambda to call **Open-Meteo** and **Anthropic** on the public internet
- EKS nodes to pull images if not fully covered by ECR endpoints (layers still use **S3 gateway** endpoint)
- AWS Load Balancer Controller to manage ALBs (also uses `elasticloadbalancing` VPC endpoint where configured)

**Isolated route table** (data + endpoint subnets): no NAT route — intended to stay without direct internet egress.

---

## VPC endpoints

`infra/10-network/endpoints.yaml` attaches endpoints so private workloads can use AWS APIs without traversing the public internet.

**Gateway endpoints (no hourly ENI charge):**

- **S3** — on all route tables (ECR layer storage)
- **DynamoDB** — on all route tables (weather results table for SQS flow)

**Interface endpoints (HTTPS :443 from VPC CIDR):**

| Service | Why it matters |
|---------|----------------|
| SSM, ssmmessages, ec2messages | Bastion access without SSH |
| ecr.api, ecr.dkr | Pull container images |
| logs | CloudWatch Logs |
| sts | IRSA and role chaining |
| ec2, autoscaling, eks | Node/cluster operations |
| elasticloadbalancing | LBC creates ALBs |
| ecs | ECS control plane |
| secretsmanager | Agent Lambda Anthropic secret |
| **execute-api** | **Private** API Gateway invoke URL from inside VPC |
| **bedrock-agentcore** | **InvokeAgentRuntime** from main app pods (Tel Aviv) |
| lambda | Lambda control plane |
| sqs | Main app sends messages (can also use NAT) |

`EndpointAvailability=single-az` (default) places one ENI per endpoint type in the first endpoint subnet; DNS still resolves VPC-wide (cross-AZ traffic possible).

---

## Public access path (CloudFront + Gateway ALB)

Not part of the base VPC template. Activated by **`make nat`**, **`make alb`**, then **`make cdn`**.

```mermaid
flowchart LR
  User["Client\n(your IP /32)"]
  CF["CloudFront + WAF"]
  S3["S3 SPA"]
  ALB["ALB\naws-project-dev-gw"]
  TG["Target group\ntargetType: ip"]
  Pod["Pod :8080"]

  User -->|"HTTPS"| CF
  CF --> S3
  CF -->|"/api/*"| ALB
  ALB --> TG --> Pod
```

- **CloudFront** default origin is the private S3 bucket (OAC). Path `/api/*` is a custom HTTP origin to the Gateway ALB (origin read timeout 60s for AgentCore).
- **WAF** (CLOUDFRONT, us-east-1) allows only `CLIENT_CIDR`.
- **ALB security group** (from the cdn stack) allows TCP 80 only from the CloudFront origin-facing prefix list. Direct browser hits to the ALB are dropped.
- **LoadBalancerConfiguration** uses that security group when `gateway.securityGroupId` is set (`make cdn` / `charts-stage`). The CRD wants SG **IDs as strings** (`securityGroups: ["sg-…"]`), not `{identifier: …}` objects (those are only for `loadBalancerSubnets`). `manageBackendSecurityGroupRules: true` keeps IP-mode pod SGs open from the ALB. Without CDN, `make alb` still uses `sourceRanges` for your `/32`.
- **TargetGroupConfiguration** (`targetType: ip`) registers **pod IPs** (port 8080). ALB subnets in every AZ where pods run.
- In-cluster Service type is **ClusterIP**.

Republish the SPA with `make cdn-sync` after UI changes (S3 sync + CloudFront invalidation). Helm/image deploy is still `make app-deploy` for API changes.

---

## DNS and service discovery

| Name | Resolves to | Consumers |
|------|-------------|-----------|
| `weather.{ProjectName}-{Environment}.local` | ECS task IPs (Cloud Map) | Main app pods (`WEATHER_SERVICE_URL`) |
| `{api-id}.execute-api.{region}.amazonaws.com` | Private API Gateway (via **execute-api** endpoint DNS) | Main app pods (`AGENT_SERVICE_URL`) |
| `bedrock-agentcore.{region}.amazonaws.com` | AgentCore data plane (via **bedrock-agentcore** endpoint) | Main app pods (`InvokeAgentRuntime`) |
| Kubernetes Service `weather-main.weather.svc` | ClusterIP | In-cluster only; HTTPRoute backend |

Cloud Map is **private DNS inside the VPC**; your laptop cannot resolve it without being in the VPC (use Gateway URL or `app-forward`).

---

## Security groups (high level)

| SG | Attached to | Notable rules |
|----|-------------|---------------|
| EKS cluster SG | Control plane ENIs | :443 from VPC CIDR |
| EKS node cluster SG | Worker nodes | Managed by EKS; LBC adds rules for ALB → pod |
| Bastion SG | Bastion EC2 | Egress; ingress none (SSM outbound-only model) |
| Lambda SG | Lambda ENIs | Egress all (NAT for Open-Meteo / Anthropic) |
| Endpoint SG | VPCE ENIs | :443 from VPC CIDR |
| LBC-managed or cdn SG | Gateway ALB | :80 from `sourceRanges` (alb) or CloudFront prefix list (`make cdn`) |

---

## Operator paths

| Goal | Path |
|------|------|
| Browse app from home | `make alb` → ALB DNS (IP allowlist) |
| Browse app via bastion | `make app-forward` → SSM → bastion `kubectl port-forward` → ClusterIP |
| Shell on bastion | `make connect` (SSM) |
| kubectl / Helm | On bastion (kubeconfig via `aws eks update-kubeconfig`) |

See [iam-and-access.md](iam-and-access.md) for credentials and roles.
