# Private image registry for the cluster. The cluster pulls only from here, never from Docker Hub at run time: the
# images are mirrored or built once by the image job (images.tf). Tags are immutable, so a pin names one image forever.

locals {
  images = {
    valkey      = { source = "valkey/valkey", tag = "8.1.10-alpine" }
    cloudflared = { source = "cloudflare/cloudflared", tag = "2026.9.3" }
    # serverless-redis-http (Upstash's REST protocol) tag 0.0.10 with images/srh-auth.patch: a 64 MB request-body limit,
    # with the token checked before any body is read.
    srh = { source = "hiett/serverless-redis-http@794c5a372fa3997e08320250235f32e5a86338a3", tag = "0.0.10-auth-body64mb" }
  }
}

resource "aws_ecr_repository" "image" {
  for_each             = local.images
  name                 = "${var.name}/${each.key}"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "image" {
  for_each   = aws_ecr_repository.image
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the ten newest images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}

locals {
  image_uri = { for k, v in local.images : k => "${aws_ecr_repository.image[k].repository_url}:${v.tag}" }
}
