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

data "aws_secretsmanager_secret" "keys" {
  name = "imgproxy-keys"
}

data "aws_secretsmanager_secret" "salts" {
  name = "imgproxy-salts"
}

data "aws_secretsmanager_secret" "pro_license" {
  name = "imgproxy-pro-license"
}

locals {
  cache_bucket = "${data.aws_caller_identity.current.account_id}-imgproxy-cache"
}

# ECR repository for the imgproxy image. The module neither creates it nor copies the image:
# create the repository, copy the image into it (see the README), then apply the module.
resource "aws_ecr_repository" "imgproxy" {
  name         = "imgproxy-pro"
  force_delete = true
}

output "repository_url" {
  value       = aws_ecr_repository.imgproxy.repository_url
  description = "ECR repository to copy the imgproxy image into"
}

module "imgproxy" {
  source  = "imgproxy/lambda-imgproxy/aws"
  version = "~> 0.1"

  service_name = "imgproxy-pro"
  repo         = aws_ecr_repository.imgproxy.repository_url
  tag          = "v4"

  pro_license_key_secret = {
    arn = data.aws_secretsmanager_secret.pro_license.arn
  }

  keys_secret = {
    arn = data.aws_secretsmanager_secret.keys.arn
  }
  salts_secret = {
    arn = data.aws_secretsmanager_secret.salts.arn
  }

  # Existing bucket (see README) for the processed-result cache (Pro)
  cache_bucket = local.cache_bucket

  environment = {
    IMGPROXY_CACHE_USE    = "s3"
    IMGPROXY_CACHE_BUCKET = local.cache_bucket
  }
}

output "url" {
  value = module.imgproxy.url
}
