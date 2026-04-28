# Production ECS Fargate Stack

Production-grade Amazon ECS Fargate infrastructure for a web application, defined end-to-end in a single Terraform root module. The stack stands up a containerized backend service, a companion Redis service for caching, an internet-facing Application Load Balancer, ECS Service Connect for service-to-service discovery, encrypted EFS-backed media storage, and SSM Parameter Store-sourced secrets. Built as a reproducible, infrastructure-as-code replacement for manual AWS console operations — every auditable resource (IAM roles, security groups, log groups, target groups, task definitions, services) is fully codified in Terraform.

## Highlights

- **Single-container Fargate task:** Application with EFS-mounted `/app/media` volume for persistent storage with in-transit encryption.
- **Dedicated Redis Fargate service** for caching, consumed by the backend over ECS Service Connect using DNS alias `redis:6379` — no hardcoded IPs, no external broker.
- **Application Load Balancer** fronting the backend with HTTP listener on :80, IP-mode target group on :8000, and a `/` health check (interval 30s, 2 healthy / 3 unhealthy thresholds).
- **Secrets management** via SSM Parameter Store (`DB_PASSWORD`, `API_KEY`) injected through the ECS execution role — no sensitive data in task definitions.
- **Purpose-built IAM:** Separate task-execution role (ECR pull, CloudWatch Logs, SSM read) and task role (scoped EFS `ClientMount`/`ClientWrite` permissions).
- **CloudWatch observability:** Per-container log groups with 14-day retention for application, cache layer, and service proxy traffic.

## Architecture

Terraform provisions the entire stack in a designated AWS region against a pre-existing VPC and ECS cluster:

1. **Service Discovery** — An `aws_service_discovery_http_namespace` provides Cloud Map backing for ECS Service Connect; a dedicated security group allows intra-service traffic and cache layer access (6379).
2. **Load Balancing** — Public Application Load Balancer → IP-mode target group on port 8000 → HTTP listener on port 80.
3. **Compute** — Two Fargate task definitions:
   - Cache service (256 CPU / 512 MB) running official Redis image
   - Application service (512 CPU / 1024 MB) running a single WSGI-compatible container
   - Both run on `FARGATE` with platform version `1.4.0` for EFS support
4. **Service-to-Service Discovery** — Both services publish themselves via Service Connect with DNS aliases (`redis:6379` and `backend:8000`), enabling internal service communication without hardcoded IPs or external brokers.
5. **Storage** — Pre-existing EFS filesystem mounted at `/app/media` with transit encryption enforced.
6. **Observability** — CloudWatch log groups per container with 14-day retention for application, cache, and service-proxy logs.

## Tech Stack

- **Infrastructure as Code:** Terraform (AWS provider; tested with 5.x)
- **AWS Services:** ECS (Fargate), ECR, Application Load Balancer, Cloud Map (Service Discovery), ECS Service Connect, EFS, CloudWatch Logs, IAM, SSM Parameter Store, VPC, Security Groups
- **Container Images:** Docker-based; application images pulled from ECR
- **Application Stack:** Django/Flask + Gunicorn (port 8000), Redis 7 for caching

## Repository Layout

```
├── README.md                      # This file: architecture and key concepts
├── .gitignore                     # Standard exclusions for Terraform state
├── main.tf                        # Complete infrastructure: IAM, security groups, 
│                                  # ALB, task definitions, services, logs, outputs
└── task.json                      # Reference task definition export (documentation only)
```

## How It Works

**Cache Service** starts first:
- Runs the official Redis image with a `redis-cli ping` health check
- Registers to Service Connect namespace as `redis` on port 6379
- Available to other services via `redis://redis:6379/0`

## Key Design Decisions

**Service Connect over Load Balancer DNS:** Internal service-to-service calls (app → cache) use Service Connect DNS aliases rather than the public load balancer, eliminating extra routing hops and external IP exposure.

**EFS for Shared Media:** Persistent storage for uploads and media assets. EFS provides scalable, shared access without forcing external dependencies.

**Secrets in SSM, not task definition:** Sensitive data (database passwords, API keys) are stored in Parameter Store and injected at runtime via the task execution role, keeping the task definition clean and auditable.

**Separate IAM roles:** Task execution role (bootstrap-time permissions: ECR pull, CloudWatch access, SSM read) vs. task role (runtime permissions: EFS access). This principle of least privilege reduces blast radius if a container is compromised.

**FARGATE platform version 1.4.0:** Explicitly pinned to ensure EFS support and consistent behavior across deployments.

## Deployment Prerequisites

- Terraform >= 1.3
- AWS CLI authenticated with appropriate IAM permissions
- Pre-existing VPC, subnets, and ECS cluster
- Pre-existing EFS filesystem for media storage
- Pre-existing ECR repository with application images
- SSM parameters for secrets management

## Running This

1. Review and customize variables in `main.tf` for your environment
2. Run `terraform init` and `terraform plan` to validate
3. Apply with `terraform apply`
4. ALB DNS endpoint available in Terraform outputs
5. Push application images to ECR; ECS auto-deploys on task definition updates
