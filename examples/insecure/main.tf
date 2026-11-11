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

module "imgproxy" {
  source  = "imgproxy/lambda-imgproxy/aws"
  version = "~> 0.1"

  service_name = "imgproxy-insecure"
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
