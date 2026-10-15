variable "name" {
  description = "Prefix for every resource (cluster, repositories, log groups, alarms)"
  type        = string
  default     = "kv"
}

variable "running" {
  description = "Start the Redis task. Keep false until the data is ready to move (see the README's migration steps)."
  type        = bool
  default     = false
}

variable "instance_secret_name" {
  description = "Secrets Manager secret holding {\"tunnel_token\", \"prod_token\", \"stage_token\"} (JSON)"
  type        = string
  default     = "kv-redis/instance"
}

variable "endpoints" {
  description = "Public REST endpoint per environment, as the tunnel publishes them (probed every minute)"
  type        = map(string)
  default = {
    prod  = "https://kv.example.com"
    stage = "https://kv-stage.example.com"
  }
}

variable "metric_namespace" {
  description = "CloudWatch namespace for the probe's Up and LatencyMs metrics"
  type        = string
  default     = "KV/Redis"
}

data "aws_region" "current" {}
