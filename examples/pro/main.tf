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

data "aws_secretsmanager_secret" "pro_registry" {
  name = "imgproxy-pro-registry"
}

locals {
  cache_bucket = "${data.aws_caller_identity.current.account_id}-imgproxy-cache"
}

module "imgproxy" {
  source  = "imgproxy/lambda-imgproxy/aws"
  version = "~> 0.1"

  service_name = "imgproxy-pro"
  tag          = "v4"

  # pro selects docker.imgproxy.pro/imgproxy as the default repo. The credentials are a JSON
  # secret with "username" and "password" keys, which Terraform uses to mirror the image to ECR.
  pro = true
  repo_credentials_secret = {
    arn = data.aws_secretsmanager_secret.pro_registry.arn
  }
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
