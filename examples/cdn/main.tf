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

module "imgproxy" {
  source  = "imgproxy/lambda-imgproxy/aws"
  version = "~> 0.1"

  service_name = "imgproxy"
  tag          = "v4"

  keys_secret = {
    arn = data.aws_secretsmanager_secret.keys.arn
  }
  salts_secret = {
    arn = data.aws_secretsmanager_secret.salts.arn
  }

  # CloudFront in front of the Function URL. The URL then accepts only requests signed by this
  # distribution (Origin Access Control), so all traffic goes through the CDN.
  enable_cloudfront = true

  # With a domain, CloudFront serves it over HTTPS using an ACM certificate issued in us-east-1:
  # cloudfront_domains         = ["cdn.example.com"]
  # cloudfront_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/..."

  cdn_default_ttl = 3600
  cdn_max_ttl     = 86400
}

output "url" {
  value = module.imgproxy.url
}

output "cloudfront_domain_name" {
  value       = module.imgproxy.cloudfront_domain_name
  description = "CloudFront domain. Point a CNAME (or a Route 53 alias) for your own domain at it"
}

output "cloudfront_hosted_zone_id" {
  value       = module.imgproxy.cloudfront_hosted_zone_id
  description = "CloudFront hosted zone ID, for Route 53 alias records"
}
