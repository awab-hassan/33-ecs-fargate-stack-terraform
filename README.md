# Project 33: ECS Fargate Stack with Service Connect, EFS, and ALB

Terraform module that provisions a complete ECS Fargate environment for a containerised web application: the application service, a Redis cache service, an internet-facing Application Load Balancer, ECS Service Connect for internal service discovery, EFS-backed persistent media storage, and SSM Parameter Store-sourced secrets. All resources (IAM roles, security groups, log groups, target groups, task definitions, services) are defined in a single Terraform root module.

## Architecture

```
Client
   |
   | HTTP :80
   v
Application Load Balancer (internet-facing)
   |
   | IP-mode target group :8000
   v
Backend service (Fargate, 512 CPU / 1024 MB)         <--- pulls image from ECR
   |                                                       reads secrets from SSM
   |  Service Connect: redis://redis:6379                  reads/writes to EFS at /app/media
   v
Redis cache service (Fargate, 256 CPU / 512 MB, Redis 7)

Both services use FARGATE platform version 1.4.0
Both publish themselves to a Service Connect namespace
Logs go to per-container CloudWatch log groups (14-day retention)
```

## What It Provisions

**Networking and discovery**
- `aws_service_discovery_http_namespace` providing Cloud Map backing for ECS Service Connect
- Security group allowing intra-service traffic and Redis access on port 6379

**Load balancing**
- Internet-facing Application Load Balancer
- IP-mode target group on port 8000 with `/` health check (interval 30s, healthy threshold 2, unhealthy threshold 3)
- HTTP listener on port 80

**Compute**
- Backend Fargate task definition (512 CPU, 1024 MB) running a WSGI-compatible application image from ECR
- Redis Fargate task definition (256 CPU, 512 MB) running official Redis 7 with `redis-cli ping` health check
- Both registered to Service Connect with DNS aliases (`backend:8000` and `redis:6379`)

**Storage**
- EFS filesystem (pre-existing) mounted at `/app/media` with transit encryption enforced

**IAM**
- Task execution role: ECR pull, CloudWatch Logs write, SSM Parameter Store read
- Task role: scoped EFS `ClientMount` and `ClientWrite` permissions only

**Observability**
- CloudWatch Log Groups per container (backend, cache, service proxy) with 14-day retention

**Secrets**
- `DB_PASSWORD` and `API_KEY` injected at task startup from SSM Parameter Store via the execution role. No secrets in the task definition.

## Key Design Decisions

**Service Connect for internal traffic.** Backend talks to Redis via the Service Connect DNS alias `redis:6379` rather than through the load balancer. No extra hop, no external IP exposure, no hardcoded addresses.

**Two IAM roles, not one.** Bootstrap-time permissions (ECR, CloudWatch, SSM) live on the execution role. Runtime permissions (EFS read/write) live on the task role. Separating them limits the blast radius if a container is compromised.

**Secrets in SSM Parameter Store.** The task definition references parameter ARNs; the execution role grants the read; ECS injects the values as environment variables at startup. No sensitive values in source control or task definitions.

**EFS for shared media.** Persistent uploads and media assets live on EFS rather than container-local storage. Survives task replacement and scales independently.

## Stack

Terraform (AWS provider 5.x) · ECS Fargate · ECR · Application Load Balancer · Cloud Map / ECS Service Connect · EFS · CloudWatch Logs · IAM · SSM Parameter Store · VPC

## Repository Layout

```
ecs-fargate-stack-terraform/
├── main.tf            # All infrastructure
├── task.json          # Reference task definition export (documentation only)
├── .gitignore
└── README.md
```

## Prerequisites

- Terraform >= 1.3
- AWS CLI configured
- Pre-existing VPC, subnets, and ECS cluster
- Pre-existing EFS filesystem
- Pre-existing ECR repository with application images pushed
- SSM Parameter Store entries for `DB_PASSWORD` and `API_KEY`

## Deployment

```bash
terraform init
terraform plan
terraform apply
```

The ALB DNS name is exposed as a Terraform output. Push new application images to ECR, then update the task definition image reference and re-apply (or deploy via a CI workflow that updates the image tag and forces a new deployment).

## Notes

- **HTTP only.** The ALB listens on port 80 with no HTTPS. Traffic between clients and the ALB is plaintext. Add an HTTPS listener with an ACM certificate and an HTTP-to-HTTPS redirect before exposing externally.
- **No service autoscaling.** Both services run at fixed task counts. Add `aws_appautoscaling_target` and `aws_appautoscaling_policy` resources tracking CPU or memory utilisation before traffic growth outpaces fixed capacity.
- **Single-replica Redis.** The cache service runs as a single Fargate task. Loss of the task means cache loss until the replacement boots. For workloads that need cache durability or high availability, use ElastiCache instead of running Redis on Fargate.
- **FARGATE platform version 1.4.0.** Pinned for historical reasons (EFS support landed in 1.4.0). EFS is supported on later versions and `LATEST` is the recommended setting today to receive security patches automatically.
- **CloudWatch retention is 14 days.** Acceptable for most use; extend if compliance or audit requirements demand longer retention.
- **No deployment circuit breaker.** ECS service deployment circuit breaker (`deployment_circuit_breaker.enable = true`) automatically rolls back failing deployments. Enable it before connecting CI for safer rollouts.
