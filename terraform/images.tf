# The image job: mirrors Valkey and cloudflared from Docker Hub and builds the patched REST server, into ecr.tf's
# repositories, on an ARM build host (the tasks run on ARM). It skips a tag that is already there, so re-running it is
# safe. Run it after a pin changes:
#   aws codebuild start-build --project-name <name>-images
# (from a session in this account), then deploy the service that uses the new tag.

resource "aws_iam_role" "images" {
  name = "${var.name}-images"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "codebuild.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "images" {
  name = "push-images"
  role = aws_iam_role.images.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      {
        Effect = "Allow"
        Action = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload", "ecr:DescribeImages",
        "ecr:GetDownloadUrlForLayer", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart"]
        Resource = [for r in aws_ecr_repository.image : r.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.images.arn}:*"
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "images" {
  name              = "/${var.name}/images"
  retention_in_days = 30
}

resource "aws_codebuild_project" "images" {
  name          = "${var.name}-images"
  description   = "Mirror and build the Redis images into ECR (images.tf)"
  service_role  = aws_iam_role.images.arn
  build_timeout = 30

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    type            = "ARM_CONTAINER"
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/amazonlinux-aarch64-standard:3.0"
    privileged_mode = true
    environment_variable {
      name  = "REGISTRY"
      value = split("/", aws_ecr_repository.image["valkey"].repository_url)[0]
    }
    environment_variable {
      name  = "SRH_PATCH_B64"
      value = base64encode(file("${path.module}/../patches/srh-auth-body64mb.patch"))
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.images.name
    }
  }

  source {
    type = "NO_SOURCE"
    buildspec = yamlencode({
      version = "0.2"
      phases = {
        build = {
          commands = concat(
            ["aws ecr get-login-password --region ${data.aws_region.current.region} | docker login --username AWS --password-stdin $REGISTRY"],
            [for k in ["valkey", "cloudflared"] :
              "if aws ecr describe-images --region ${data.aws_region.current.region} --repository-name ${var.name}/${k} --image-ids imageTag=${local.images[k].tag} >/dev/null 2>&1; then echo ${k} present; else docker pull --platform linux/arm64 ${local.images[k].source}:${local.images[k].tag} && docker tag ${local.images[k].source}:${local.images[k].tag} ${local.image_uri[k]} && docker push ${local.image_uri[k]}; fi"
            ],
            [
              "if aws ecr describe-images --region ${data.aws_region.current.region} --repository-name ${var.name}/srh --image-ids imageTag=${local.images.srh.tag} >/dev/null 2>&1; then echo srh present; else git clone -q https://github.com/hiett/serverless-redis-http /tmp/srh && git -C /tmp/srh checkout -q ${split("@", local.images.srh.source)[1]} && echo \"$SRH_PATCH_B64\" | base64 -d > /tmp/srh.patch && git -C /tmp/srh apply /tmp/srh.patch && docker build -t ${local.image_uri.srh} /tmp/srh && docker push ${local.image_uri.srh}; fi",
            ],
          )
        }
      }
    })
  }
}
