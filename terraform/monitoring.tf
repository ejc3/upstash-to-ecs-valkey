# Monitoring for the cluster and its services. Every alarm notifies aws_sns_topic.alerts (ecs.tf), on ALARM and OK.
#
#   redis-endpoint-down-<env>  the probe (every minute, a real PING/SET/GET through the public endpoint) failed 3 minutes
#                              running, or stopped reporting: the end-to-end check, tunnel and REST server included
#   redis-not-running          the service has no running task (only while local.redis_running)
#   redis-cpu-high / -memory-high  the task is near its size
#   redis-probe-errors         the probe itself fails
# Container Insights (enhanced, ecs.tf) adds per-task and per-container metrics, and the dashboard shows them together.

data "archive_file" "redis_probe" {
  type        = "zip"
  source_file = "${path.module}/../lambda/redis_probe.py"
  output_path = "${path.module}/.build/redis_probe.zip"
}

resource "aws_iam_role" "redis_probe" {
  name = "${var.name}-redis-probe"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "redis_probe" {
  name = "probe"
  role = aws_iam_role.redis_probe.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "secretsmanager:GetSecretValue", Resource = data.aws_secretsmanager_secret.redis_instance.arn },
      {
        Effect    = "Allow"
        Action    = "cloudwatch:PutMetricData"
        Resource  = "*"
        Condition = { StringEquals = { "cloudwatch:namespace" = var.metric_namespace } }
      },
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.redis_probe.arn}:*" },
    ]
  })
}

resource "aws_cloudwatch_log_group" "redis_probe" {
  name              = "/aws/lambda/${var.name}-redis-probe"
  retention_in_days = 30
}

resource "aws_lambda_function" "redis_probe" {
  function_name    = "${var.name}-redis-probe"
  role             = aws_iam_role.redis_probe.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "redis_probe.handler"
  filename         = data.archive_file.redis_probe.output_path
  source_code_hash = data.archive_file.redis_probe.output_base64sha256
  timeout          = 30
  memory_size      = 128
  environment {
    variables = {
      SECRET_ID        = data.aws_secretsmanager_secret.redis_instance.name
      ENDPOINTS        = jsonencode(var.endpoints)
      METRIC_NAMESPACE = var.metric_namespace
    }
  }
  depends_on = [aws_cloudwatch_log_group.redis_probe]
}

resource "aws_cloudwatch_event_rule" "redis_probe" {
  name                = "${var.name}-redis-probe"
  description         = "Probe the Redis REST endpoints every minute"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "redis_probe" {
  rule = aws_cloudwatch_event_rule.redis_probe.name
  arn  = aws_lambda_function.redis_probe.arn
}

resource "aws_lambda_permission" "redis_probe" {
  statement_id  = "events"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.redis_probe.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.redis_probe.arn
}

resource "aws_cloudwatch_metric_alarm" "redis_endpoint_down" {
  for_each            = local.redis_envs
  alarm_name          = "${var.name}-redis-endpoint-down-${each.key}"
  alarm_description   = "The ${each.key} Redis endpoint failed its probe (PING/SET/GET through the public hostname) 3 minutes running, or the probe stopped reporting."
  namespace           = var.metric_namespace
  metric_name         = "Up"
  dimensions          = { Endpoint = each.key }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "redis_not_running" {
  count               = local.redis_running ? 1 : 0
  alarm_name          = "${var.name}-redis-not-running"
  alarm_description   = "The Redis service has no running task."
  namespace           = "ECS/ContainerInsights"
  metric_name         = "RunningTaskCount"
  dimensions          = { ClusterName = aws_ecs_cluster.this.name, ServiceName = aws_ecs_service.redis.name }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "redis_usage" {
  for_each = {
    cpu    = { metric = "CPUUtilization", threshold = 80 }
    memory = { metric = "MemoryUtilization", threshold = 85 }
  }
  alarm_name          = "${var.name}-redis-${each.key}-high"
  alarm_description   = "The Redis task's ${each.key} has been above ${each.value.threshold}% for 15 minutes: give it a bigger task size."
  namespace           = "AWS/ECS"
  metric_name         = each.value.metric
  dimensions          = { ClusterName = aws_ecs_cluster.this.name, ServiceName = aws_ecs_service.redis.name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "redis_probe_errors" {
  alarm_name          = "${var.name}-redis-probe-errors"
  alarm_description   = "The Redis probe Lambda is failing (its own errors, not the endpoints')."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.redis_probe.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = "${var.name}-platform"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = { title = "Redis endpoints up (probe)", region = data.aws_region.current.region, stat = "Minimum", period = 60,
        metrics = [for env in keys(local.redis_envs) : [var.metric_namespace, "Up", "Endpoint", env]] }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = { title = "Redis round trip (ms)", region = data.aws_region.current.region, stat = "p90", period = 60,
        metrics = [for env in keys(local.redis_envs) : [var.metric_namespace, "LatencyMs", "Endpoint", env]] }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = { title = "Redis task CPU and memory (%)", region = data.aws_region.current.region, stat = "Average", period = 300,
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.this.name, "ServiceName", aws_ecs_service.redis.name],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", aws_ecs_cluster.this.name, "ServiceName", aws_ecs_service.redis.name],
        ] }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = { title = "Running tasks", region = data.aws_region.current.region, stat = "Minimum", period = 60,
        metrics = [["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", aws_ecs_cluster.this.name, "ServiceName", aws_ecs_service.redis.name]] }
      },
    ]
  })
}
