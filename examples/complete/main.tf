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

# Optional secrets, used by the commented-out options below
# data "aws_secretsmanager_secret" "secret" {
#   name = "imgproxy-secret"
# }
# data "aws_secretsmanager_secret" "source_url_key" {
#   name = "imgproxy-source-url-key"
# }

locals {
  source_bucket = "${data.aws_caller_identity.current.account_id}-imgproxy-complete-source"
  cache_bucket  = "${data.aws_caller_identity.current.account_id}-imgproxy-complete-cache"
}

module "imgproxy" {
  source  = "imgproxy/lambda-imgproxy/aws"
  version = "~> 0.1"

  service_name = "imgproxy"
  tag          = "v4"

  # Security: request signing
  keys_secret = {
    arn = data.aws_secretsmanager_secret.keys.arn
  }
  salts_secret = {
    arn = data.aws_secretsmanager_secret.salts.arn
  }
  signature_size = 32

  # Optional: Bearer token auth (cannot be used with enable_cloudfront = true)
  # secret_secret = {
  #   arn = data.aws_secretsmanager_secret.secret.arn
  # }

  # Optional: source URL encryption
  # source_url_encryption_key_secret = {
  #   arn = data.aws_secretsmanager_secret.source_url_key.arn
  # }

  # imgproxy Pro. The registry credentials are a JSON secret with "username" and "password" keys.
  pro = true
  repo_credentials_secret = {
    arn = data.aws_secretsmanager_secret.pro_registry.arn
  }
  pro_license_key_secret = {
    arn = data.aws_secretsmanager_secret.pro_license.arn
  }

  # Optional: mirror from your own registry instead (pro then no longer affects the image).
  # Registries other than ECR need repo_credentials_secret.
  # repo = "registry.example.com/imgproxy-custom"

  # Optional: skip mirroring and run an image you already pushed to ECR in this account and region
  # image_uri = "123456789012.dkr.ecr.us-east-1.amazonaws.com/imgproxy@sha256:..."

  # Optional: trusted signatures (Pro only)
  # trusted_signatures_secret = {
  #   arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy-trusted-sigs-AbCdEf"
  # }

  # Optional: additional secrets for third-party integrations
  # secrets = {
  #   IMGPROXY_NEW_RELIC_KEY = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:newrelic-license-AbCdEf" }
  #   IMGPROXY_SENTRY_DSN    = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sentry-dsn-AbCdEf", version = "3" }
  # }

  # Existing buckets (see README): source images and result cache (Pro)
  source_buckets = [local.source_bucket]
  cache_bucket   = local.cache_bucket

  # Monitoring: X-Ray tracing and imgproxy CloudWatch metrics
  enable_monitoring = true

  # Compute resources: about 2.3 vCPU. imgproxy handles one request per function instance.
  architecture           = "arm64"
  memory_size            = 4096
  ephemeral_storage_size = 1024
  timeout                = 60 # imgproxy request timeout
  function_timeout       = 90 # Lambda timeout, must be above it

  # Scaling: keep 2 instances warm (billed continuously) and cap the total at 50
  provisioned_concurrency = 2
  reserved_concurrency    = 50

  # Optional: attach the function to a VPC to reach private resources. The subnets need a NAT
  # gateway (imgproxy fetches source images from the internet) or VPC endpoints for S3 and
  # Secrets Manager.
  # vpc_id     = "vpc-0123456789abcdef0"
  # subnet_ids = ["subnet-0aaa...", "subnet-0bbb..."]

  # CloudFront CDN. The Function URL then accepts only requests signed by the distribution.
  enable_cloudfront = true
  # cloudfront_domains              = ["cdn.example.com"]
  # cloudfront_certificate_arn      = "arn:aws:acm:us-east-1:123456789012:certificate/..."
  # cloudfront_origin_shield_region = "us-east-1"
  # cdn_default_ttl                 = 3600
  # cdn_max_ttl                     = 86400

  # Logs
  log_retention_days = 90

  # Tags
  tags = {
    app  = "imgproxy"
    team = "platform"
  }

  # Additional imgproxy configuration
  environment = {
    IMGPROXY_MAX_SRC_RESOLUTION = "50.0"
    IMGPROXY_JPEG_PROGRESSIVE   = "true"
    IMGPROXY_S3_REGION          = var.region
    IMGPROXY_CACHE_USE          = "s3"
    IMGPROXY_CACHE_BUCKET       = local.cache_bucket
  }
}

output "url" {
  description = "The URL of the deployed imgproxy service"
  value       = module.imgproxy.url
}

output "function_url" {
  description = "The Function URL behind CloudFront (IAM-protected)"
  value       = module.imgproxy.function_url
}

output "cloudfront_domain_name" {
  description = "CloudFront domain. Point a CNAME (or a Route 53 alias) for your own domain at it"
  value       = module.imgproxy.cloudfront_domain_name
}

output "log_group_name" {
  description = "CloudWatch Logs group of imgproxy"
  value       = module.imgproxy.log_group_name
}
