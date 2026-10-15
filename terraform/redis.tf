# Redis on the cluster: one task of four containers.
#   valkey       the store; its append-only file is on EFS (replicated across zones, AWS Backup daily)
#   srh-prod     Upstash's REST protocol (serverless-redis-http) for production (db 0) on 127.0.0.1:8079
#   srh-stage    the same for staging (db 1) on 127.0.0.1:8078
#   cloudflared  dials OUT to Cloudflare; a tunnel publishes one hostname per environment (var.endpoints)
# No inbound rule anywhere: the REST token is the credential, as with Upstash. The tunnel, its DNS records and the tokens
# are created outside this module (they are Cloudflare's); the task reads them from one Secrets Manager secret,
# var.instance_secret_name: JSON {"tunnel_token": "...", "prod_token": "...", "stage_token": "..."}.
#
# Failover time (measured: task stopped -> endpoint answering, 108 s with 15 s health checks): about 40 s is Fargate
# starting a task (placement, network interface, image pull, EFS mount), which no setting here changes; the rest is the
# startup chain, each step waiting for the previous container's health check. Checks run every 5 s (the ECS minimum)
# with short start periods, so each step unblocks within seconds of being ready.
#
# One copy only, ever: two Valkeys on one append-only file corrupt it, and two cloudflared connectors on one tunnel would
# split writes between two stores. So the service runs one task, and a deploy stops the old task before starting the new
# one. var.running is the switch for a migration: false creates everything with no task; true starts it once the old
# store has stopped serving.

locals {
  redis_running = var.running
  redis_envs = {
    prod  = { port = 8079, db = 0 }
    stage = { port = 8078, db = 1 }
  }
}

data "aws_secretsmanager_secret" "redis_instance" {
  name = var.instance_secret_name
}

resource "aws_security_group" "redis_task" {
  name        = "${var.name}-redis-task"
  description = "Redis task: no inbound; outbound to Cloudflare, ECR, Secrets Manager and EFS"
  vpc_id      = data.aws_vpc.default.id
  egress {
    description = "Cloudflare tunnel, ECR, Secrets Manager, CloudWatch and EFS"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "redis_efs" {
  name        = "${var.name}-redis-efs"
  description = "Redis data: NFS from the Redis task only"
  vpc_id      = data.aws_vpc.default.id
  ingress {
    description     = "NFS from the Redis task"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.redis_task.id]
  }
}

resource "aws_efs_file_system" "redis" {
  creation_token = "${var.name}-redis"
  encrypted      = true
  tags           = { Name = "${var.name}-redis" }
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_efs_backup_policy" "redis" {
  file_system_id = aws_efs_file_system.redis.id
  backup_policy {
    status = "ENABLED"
  }
}

resource "aws_efs_mount_target" "redis" {
  for_each        = toset(data.aws_subnets.default.ids)
  file_system_id  = aws_efs_file_system.redis.id
  subnet_id       = each.value
  security_groups = [aws_security_group.redis_efs.id]
}

# Valkey runs as uid 999; the access point makes every write that user's, under /valkey.
resource "aws_efs_access_point" "redis" {
  file_system_id = aws_efs_file_system.redis.id
  posix_user {
    uid = 999
    gid = 1000
  }
  root_directory {
    path = "/valkey"
    creation_info {
      owner_uid   = 999
      owner_gid   = 1000
      permissions = "0750"
    }
  }
}

resource "aws_iam_role_policy" "ecs_execution_redis" {
  name = "redis-secrets"
  role = aws_iam_role.ecs_execution.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "secretsmanager:GetSecretValue", Resource = data.aws_secretsmanager_secret.redis_instance.arn }]
  })
}

# The task's own role: mount its EFS access point, and ECS Exec for debugging (`aws ecs execute-command`).
resource "aws_iam_role" "redis_task" {
  name = "${var.name}-redis-task"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "redis_task" {
  name = "efs-and-exec"
  role = aws_iam_role.redis_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]
        Resource  = aws_efs_file_system.redis.arn
        Condition = { StringEquals = { "elasticfilesystem:AccessPointArn" = aws_efs_access_point.redis.arn } }
      },
      {
        Effect   = "Allow"
        Action   = ["ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel", "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "redis" {
  name              = "/${var.name}/redis"
  retention_in_days = 30
}

locals {
  redis_log = { for name in ["valkey", "srh-prod", "srh-stage", "cloudflared"] : name => {
    logDriver = "awslogs"
    options   = { "awslogs-group" = aws_cloudwatch_log_group.redis.name, "awslogs-region" = data.aws_region.current.region, "awslogs-stream-prefix" = name }
  } }
}

resource "aws_ecs_task_definition" "redis" {
  family                   = "${var.name}-redis"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.redis_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  volume {
    name = "valkey-data"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.redis.id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.redis.id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode(concat(
    [{
      name      = "valkey"
      image     = local.image_uri.valkey
      essential = true
      user      = "999:1000"
      command = ["valkey-server", "--dir", "/data", "--appendonly", "yes", "--appendfsync", "everysec", "--save", "900 1",
      "--maxmemory", "384mb", "--maxmemory-policy", "noeviction"]
      mountPoints      = [{ sourceVolume = "valkey-data", containerPath = "/data" }]
      healthCheck      = { command = ["CMD", "valkey-cli", "ping"], interval = 5, timeout = 3, retries = 2, startPeriod = 5 }
      stopTimeout      = 10
      logConfiguration = local.redis_log["valkey"]
    }],
    [for env, r in local.redis_envs : {
      name      = "srh-${env}"
      image     = local.image_uri.srh
      essential = true
      environment = [
        { name = "SRH_MODE", value = "env" },
        # Every container in an awsvpc task shares one hostname, and both servers are Elixir releases named `prod`: with
        # the default node name the second one finds prod@<host> taken and exits (2026-10-15, the first start here).
        { name = "RELEASE_NODE", value = "srh_${env}" },
        { name = "SRH_PORT", value = tostring(r.port) },
        { name = "SRH_CONNECTION_STRING", value = "redis://127.0.0.1:6379/${r.db}" },
      ]
      secrets          = [{ name = "SRH_TOKEN", valueFrom = "${data.aws_secretsmanager_secret.redis_instance.arn}:${env}_token::" }]
      dependsOn        = [{ containerName = "valkey", condition = "HEALTHY" }]
      healthCheck      = { command = ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:${r.port}/ || exit 1"], interval = 5, timeout = 3, retries = 2, startPeriod = 10 }
      stopTimeout      = 10
      logConfiguration = local.redis_log["srh-${env}"]
    }],
    [{
      name             = "cloudflared"
      image            = local.image_uri.cloudflared
      essential        = true
      command          = ["tunnel", "--no-autoupdate", "run"]
      secrets          = [{ name = "TUNNEL_TOKEN", valueFrom = "${data.aws_secretsmanager_secret.redis_instance.arn}:tunnel_token::" }]
      dependsOn        = [for env in keys(local.redis_envs) : { containerName = "srh-${env}", condition = "HEALTHY" }]
      stopTimeout      = 10
      logConfiguration = local.redis_log["cloudflared"]
    }],
  ))
}

resource "aws_ecs_service" "redis" {
  name                   = "redis"
  cluster                = aws_ecs_cluster.this.id
  task_definition        = aws_ecs_task_definition.redis.arn
  desired_count          = local.redis_running ? 1 : 0
  launch_type            = "FARGATE"
  enable_execute_command = true
  propagate_tags         = "SERVICE"

  # Stop the old task before the new one starts: never two copies (see the header).
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.redis_task.id]
    assign_public_ip = true
  }

  depends_on = [aws_efs_mount_target.redis, aws_iam_role_policy.ecs_execution_redis]
}
