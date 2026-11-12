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

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ECR repository for the imgproxy image. The module neither creates it nor copies the image:
# create the repository, copy the image into it (see the README), then apply the module.
resource "aws_ecr_repository" "imgproxy" {
  name         = "imgproxy-insecure"
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

  service_name = "imgproxy-insecure"
  repo         = aws_ecr_repository.imgproxy.repository_url
  tag          = "v4"

  # WARNING: Insecure mode - no request signing
  # Use only for development/testing
  insecure = true
}

output "url" {
  description = "The URL of the deployed imgproxy service"
  value       = module.imgproxy.url
}

output "warning" {
  description = "Security warning"
  value       = "⚠️  This deployment runs in INSECURE mode with no request signing. Do not use in production!"
}
