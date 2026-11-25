terraform {
  required_version = ">= 1.15"

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

# ECR repository for the imgproxy image. The module neither creates it nor copies the image:
# create the repository, copy the image into it (see the README), then apply the module.
resource "aws_ecr_repository" "imgproxy" {
  name         = "imgproxy"
  force_delete = true
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

  # Function size. Lambda allocates CPU in proportion to memory: about 1 vCPU per 1769 MB.
  memory_size            = 2048    # MB, 128-10240
  ephemeral_storage_size = 512     # MB of /tmp, 512-10240
  architecture           = "arm64" # Graviton: cheaper, same performance. The image must match

  # Timeouts. imgproxy's own timeout must stay below the function timeout.
  function_timeout = 30 # seconds, 1-900
  timeout          = 25 # seconds, IMGPROXY_TIMEOUT

  # Concurrency. Lambda starts a function instance per concurrent request, so this is the scaling
  # control: there are no instances or workers to size (imgproxy always runs with one worker).
  # reserved_concurrency caps executions: it protects the account limit and bounds the cost.
  # provisioned_concurrency keeps instances warm to remove cold starts for that many concurrent
  # requests. It is billed continuously, so it is 0 here; it must not exceed reserved_concurrency.
  reserved_concurrency    = 50
  provisioned_concurrency = 0

  # Production: put the function in private subnets only when it must reach private resources.
  # The subnets need a NAT gateway; see "Production setup" in the README.
  # vpc_id     = "vpc-0123456789abcdef0"
  # subnet_ids = ["subnet-0aaa...", "subnet-0bbb..."]
}

output "url" {
  value = module.imgproxy.url
}

