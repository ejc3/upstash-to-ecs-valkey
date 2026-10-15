# The container platform. Fargate only: AWS runs the hardware, so there is no host to patch, size or replace, and a task
# that dies is started again by the service.

resource "aws_ecs_cluster" "this" {
  name = var.name
  setting {
    name  = "containerInsights"
    value = "enhanced"
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

# Every alarm on the platform goes here. Subscribe an email address (or a chat webhook) to it outside this module, so no
# address is written into the code:
#   aws sns subscribe --topic-arn <alerts_topic> --protocol email --notification-endpoint you@example.com
resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# Lets the ECS agent pull images and write logs for every service on the cluster, and read only the secrets a service
# names (each service adds its own statement).
resource "aws_iam_role" "ecs_execution" {
  name = "${var.name}-ecs-execution"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

output "ecs" {
  description = "The ECS cluster and its alert topic"
  value = {
    cluster      = aws_ecs_cluster.this.name
    alerts_topic = aws_sns_topic.alerts.arn
  }
}
