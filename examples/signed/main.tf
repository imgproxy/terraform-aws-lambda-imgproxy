terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.28"
    }
  }
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "profile" {
  description = "AWS CLI profile used by the provider (null = default credentials / AWS_PROFILE)"
  type        = string
  default     = null
}

provider "aws" {
  region  = var.region
  profile = var.profile
}

data "aws_secretsmanager_secret" "keys" {
  name = "imgproxy-keys"
}

data "aws_secretsmanager_secret" "salts" {
  name = "imgproxy-salts"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ECR repository for the imgproxy image. The module neither creates it nor copies the image:
# create the repository, copy the image into it (see the README), then apply the module.
resource "aws_ecr_repository" "imgproxy" {
  name         = "imgproxy"
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Lets the Lambda service pull the image.
resource "aws_ecr_repository_policy" "imgproxy" {
  repository = aws_ecr_repository.imgproxy.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "LambdaPull"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
      Condition = {
        StringLike = {
          "aws:sourceArn" = "arn:aws:lambda:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:function:*"
        }
      }
    }]
  })
}

output "repository_url" {
  value       = aws_ecr_repository.imgproxy.repository_url
  description = "ECR repository to copy the imgproxy image into"
}

module "imgproxy" {
  source  = "imgproxy/lambda-imgproxy/aws"
  version = "~> 0.1"

  service_name = "imgproxy"
  repo         = aws_ecr_repository.imgproxy.repository_url
  tag          = "v4"

  # Request signing (required for production)
  keys_secret = {
    arn = data.aws_secretsmanager_secret.keys.arn
  }
  salts_secret = {
    arn = data.aws_secretsmanager_secret.salts.arn
  }

  # Production: put the function in private subnets only when it must reach private resources.
  # The subnets need a NAT gateway (imgproxy fetches source images from the internet); see
  # "Production setup" in the README.
  # vpc_id     = "vpc-0123456789abcdef0"
  # subnet_ids = ["subnet-0aaa...", "subnet-0bbb..."]

  # Production: reserve concurrency to cap cost and protect the account limit.
  # reserved_concurrency = 50
}

output "url" {
  value = module.imgproxy.url
}

