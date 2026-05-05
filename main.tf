provider "aws" {
  region  = "us-west-2"
}

locals {
  environment_name = "prod"
  app_name         = "myapp"
  vpc_id           = "vpc-XXX"
  subnet_ids       = ["subnet-XXX", "subnet-XXX"]
  backend_sg_id    = ["sg-XXX", "sg-XXX", "sg-XXX"]
  redis_sg_id      = "sg-XXX"
  alb_sg_id        = "sg-XXX"
  efs_id           = "fs-XXX"
}

# Create a security group for Service Connect traffic
resource "aws_security_group" "service_connect_sg" {
  name        = "${local.app_name}-service-connect"
  description = "Security group for Service Connect communication"
  vpc_id      = local.vpc_id

  # Allow all traffic between services in this security group
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
    description = "Allow all traffic between services"
  }

  # Allow Redis port from anywhere in the VPC
  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow Redis traffic"
  }

  # Allow outbound traffic to anywhere
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = "${local.app_name}-service-connect-sg"
  }
}

# AWS Cloud Map Namespace for Service Connect
resource "aws_service_discovery_http_namespace" "service_connect" {
  name        = "${local.app_name}-namespace-prod"
  description = "Service Connect namespace for application services"
}

# IAM Roles
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${local.app_name}-task-execution"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_ssm_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess"
}

resource "aws_iam_role" "ecs_task_role" {
  name = "${local.app_name}-task"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_policy" "efs_access_policy" {
  name = "${local.app_name}-efs-access"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "elasticfilesystem:ClientMount",
          "elasticfilesystem:ClientWrite"
        ]
        Resource = "arn:aws:elasticfilesystem:us-west-2:*:file-system/${local.efs_id}"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_role_efs_policy" {
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = aws_iam_policy.efs_access_policy.arn
}

# CloudWatch Log Groups
resource "aws_cloudwatch_log_group" "backend_log_group" {
  name              = "/ecs/${local.app_name}-backend-${local.environment_name}"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "redis_log_group" {
  name              = "/ecs/${local.app_name}-redis-${local.environment_name}"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "service_connect_log_group" {
  name              = "/ecs/service-connect-proxy-${local.environment_name}"
  retention_in_days = 14
}

# Load Balancer
resource "aws_lb" "backend_alb" {
  name               = "${local.app_name}-backend-alb-${local.environment_name}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [local.alb_sg_id]
  subnets            = local.subnet_ids

  enable_deletion_protection = false

  idle_timeout = 60
}

resource "aws_lb_target_group" "backend_target_group" {
  name        = "${local.app_name}-tg-${local.environment_name}"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = local.vpc_id
  target_type = "ip"

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 20
}

# The HTTPS Listener (Terminates SSL and forwards to Target Group)
resource "aws_lb_listener" "https_listener" {
  load_balancer_arn = aws_lb.backend_alb.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS-1-2-2017-01" # Upgraded security policy
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend_target_group.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.backend_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# Data source to get the current AWS account ID
data "aws_caller_identity" "current" {}

# Redis Task Definition
resource "aws_ecs_task_definition" "redis" {
  family                   = "${local.app_name}-redis-${local.environment_name}"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"

  container_definitions = jsonencode([
    {
      name      = "redis"
      image     = "redis:latest"
      essential = true
      portMappings = [
        {
          name          = "redis-port"
          containerPort = 6379
          hostPort      = 6379
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.redis_log_group.name
          "awslogs-region"        = "us-west-2"
          "awslogs-stream-prefix" = "redis"
        }
      }
      healthCheck = {
        command     = ["CMD-SHELL", "redis-cli ping || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 10
      }
    }
  ])
}

# Get existing ECS cluster
data "aws_ecs_cluster" "existing" {
  cluster_name = "myapp-prod"
}

# Redis Service
resource "aws_ecs_service" "redis" {
  name                              = "${local.app_name}-redis-${local.environment_name}"
  cluster                           = data.aws_ecs_cluster.existing.arn
  task_definition                   = aws_ecs_task_definition.redis.arn
  desired_count                     = 1
  launch_type                       = "FARGATE"
  platform_version                  = "LATEST"
  scheduling_strategy               = "REPLICA"
  health_check_grace_period_seconds = 120

  network_configuration {
    subnets          = local.subnet_ids
    security_groups  = [aws_security_group.service_connect_sg.id, local.redis_sg_id]
    assign_public_ip = true
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.service_connect.name

    log_configuration {
      log_driver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.service_connect_log_group.name
        "awslogs-region"        = "us-west-2"
        "awslogs-stream-prefix" = "redis-service-connect"
      }
    }

    service {
      port_name      = "redis-port"
      discovery_name = "redis"
      client_alias {
        port     = 6379
        dns_name = "redis"
      }
    }
  }

  depends_on = [aws_service_discovery_http_namespace.service_connect]
}

# Backend Task Definition
resource "aws_ecs_task_definition" "backend" {
  family                   = "${local.app_name}-backend-${local.environment_name}"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"

  container_definitions = jsonencode([
    {
      name      = "backend"
      image     = "<your-account-id>.dkr.ecr.us-west-2.amazonaws.com/myapp/backend:latest"
      essential = true
      command   = ["gunicorn", "myapp.wsgi:application", "--bind", "0.0.0.0:8000"]
      workingDirectory = "/myapp"
      portMappings = [
        {
          name          = "backend-port"
          containerPort = 8000
          hostPort      = 8000
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "DB_NAME", value = "myapp" },
        { name = "DB_USER", value = "postgres" },
        { name = "DB_HOST", value = "db.example.com" },
        { name = "DB_PORT", value = "5432" },
        { name = "JWT_ACCESS_TOKEN_LIFETIME", value = "60" },
        { name = "JWT_REFRESH_TOKEN_LIFETIME", value = "1" },
        { name = "JWT_ALGORITHM", value = "HS256" },
        { name = "PYTHONPATH", value = "/myapp" },
        { name = "REDIS_URL", value = "redis://redis:6379/0" }
      ]
      secrets = [
        { name = "DB_PASSWORD", valueFrom = "arn:aws:ssm:us-west-2:${data.aws_caller_identity.current.account_id}:parameter/myapp/db-password-prod" },
        { name = "JWT_SIGNING_KEY", valueFrom = "arn:aws:ssm:us-west-2:${data.aws_caller_identity.current.account_id}:parameter/myapp/jwt-signing-key" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.backend_log_group.name
          "awslogs-region"        = "us-west-2"
          "awslogs-stream-prefix" = "backend"
        }
      }
      mountPoints = [
        {
          sourceVolume  = "media-volume"
          containerPath = "/myapp/media"
          readOnly      = false
        }
      ]
    }
  ])

  volume {
    name = "media-volume"

    efs_volume_configuration {
      file_system_id     = local.efs_id
      root_directory     = "/media-prod"
      transit_encryption = "ENABLED"
    }
  }
}

# Backend Service
resource "aws_ecs_service" "backend" {
  name                              = "${local.app_name}-backend-${local.environment_name}"
  cluster                           = data.aws_ecs_cluster.existing.arn
  task_definition                   = aws_ecs_task_definition.backend.arn
  desired_count                     = 1
  launch_type                       = "FARGATE"
  platform_version                  = "1.4.0"
  scheduling_strategy               = "REPLICA"
  health_check_grace_period_seconds = 120

  network_configuration {
    subnets          = local.subnet_ids
    security_groups  = ["sg-XXX", "sg-XXX"]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.backend_target_group.arn
    container_name   = "backend"
    container_port   = 8000
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.service_connect.name

    log_configuration {
      log_driver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.service_connect_log_group.name
        "awslogs-region"        = "us-west-2"
        "awslogs-stream-prefix" = "backend-service-connect"
      }
    }

    service {
      port_name      = "backend-port"
      discovery_name = "backend"
      client_alias {
        port     = 8000
        dns_name = "backend"
      }
    }
  }

  depends_on = [
    aws_service_discovery_http_namespace.service_connect,
    aws_ecs_service.redis,
    aws_lb_listener.http_listener
  ]
}

# Outputs
output "backend_url" {
  description = "URL of the backend load balancer"
  value       = "http://${aws_lb.backend_alb.dns_name}"
}

output "namespace_id" {
  description = "Service Connect Namespace ID"
  value       = aws_service_discovery_http_namespace.service_connect.id
}

output "namespace_name" {
  description = "Service Connect Namespace Name"
  value       = aws_service_discovery_http_namespace.service_connect.name
}

output "backend_service_name" {
  description = "Backend Service Name"
  value       = aws_ecs_service.backend.name
}

output "redis_service_name" {
  description = "Redis Service Name"
  value       = aws_ecs_service.redis.name
}

output "service_connect_sg_id" {
  description = "Service Connect Security Group ID"
  value       = aws_security_group.service_connect_sg.id
}
