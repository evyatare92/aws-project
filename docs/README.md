# Weather Board — documentation

This folder describes how the **aws-project** Weather Board is built and how traffic flows from your browser to four different weather backends.

| Document | Contents |
|----------|----------|
| [architecture/overview.md](architecture/overview.md) | System context, CloudFormation stacks, deployment model, main diagrams |
| [architecture/network-and-routing.md](architecture/network-and-routing.md) | VPC layout, subnets, route tables, NAT, VPC endpoints, public Gateway ALB |
| [architecture/kubernetes-and-gateway.md](architecture/kubernetes-and-gateway.md) | EKS, Helm, IRSA, Gateway API, AWS Load Balancer Controller |
| [architecture/weather-backends.md](architecture/weather-backends.md) | Per-city backends (ECS, agent Lambda, SQS Lambda), API contracts, sequence flows |
| [architecture/iam-and-access.md](architecture/iam-and-access.md) | IAM roles, who assumes what, bastion and operator access |

Same-region HA: per-AZ NAT (see network doc), multi-AZ VPC endpoints (`ENDPOINT_AZ=multi-az`), 2+ EKS nodes / main pods / ECS weather tasks, Gateway ALB across three public subnets.

Infrastructure lives under `infra/`; applications under `app/`; Helm charts under `deploy/charts/`. The root `Makefile` orchestrates deploy and day‑2 operations.
