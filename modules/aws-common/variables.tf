# ── Core ──────────────────────────────────────────────────────────────────────

variable "service_name" {
  type        = string
  description = "Prefix applied to all created resource names."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to all created resources."
}

variable "compute_platform" {
  type        = string
  default     = "ecs"
  description = "Compute platform the shared resources are created for: \"ecs\" (Fargate and EC2) or \"lambda\". With \"lambda\" the task role becomes the Lambda function role, no ECS execution role is created, and CloudFront uses a Lambda Function URL origin with Origin Access Control."

  validation {
    condition     = contains(["ecs", "lambda"], var.compute_platform)
    error_message = "compute_platform must be \"ecs\" or \"lambda\"."
  }
}

# ── IAM ───────────────────────────────────────────────────────────────────────

variable "execution_role_arn" {
  type        = string
  default     = null
  description = "ARN of an existing execution role. When null, a role is created."
}

variable "task_role_arn" {
  type        = string
  default     = null
  description = "ARN of an existing task role. When null, a role is created."
}

variable "source_buckets" {
  type        = list(string)
  default     = []
  description = "S3 bucket names granted read access on the task role."
}

variable "cache_bucket" {
  type        = string
  default     = null
  description = "S3 bucket name granted read/write access on the task role."
}

variable "enable_monitoring" {
  type        = bool
  default     = false
  description = "When true, adds X-Ray and CloudWatch permissions to the task role."
}

variable "secret_arns" {
  type        = list(string)
  default     = []
  description = "Secrets Manager ARNs the execution role is allowed to read."
}

# ── Logging ───────────────────────────────────────────────────────────────────

variable "log_group_name" {
  type        = string
  default     = null
  description = "CloudWatch log group name. Defaults to /aws/ecs/<service_name>; Lambda requires /aws/lambda/<function name>."
}

variable "log_retention_days" {
  type        = number
  default     = 365
  description = "CloudWatch log group retention in days."
}

# ── Network ───────────────────────────────────────────────────────────────────

variable "vpc_id" {
  type        = string
  default     = null
  description = "VPC ID. Required when create_alb = true."
}

variable "subnet_ids" {
  type        = list(string)
  default     = []
  description = "Subnet IDs for the ALB when alb_subnet_ids is null."
}

variable "alb_subnet_ids" {
  type        = list(string)
  default     = null
  description = "Subnet IDs for the ALB. Defaults to subnet_ids when null."
}

# ── Lambda ────────────────────────────────────────────────────────────────────

variable "lambda_function_url" {
  type        = string
  default     = null
  description = "Lambda Function URL used as the CloudFront origin. Required when compute_platform = \"lambda\" and enable_cloudfront = true."
}

variable "lambda_vpc_access" {
  type        = bool
  default     = false
  description = "Attach the AWS-managed VPC access policy to the Lambda function role (needed when the function is attached to a VPC)."
}

# ── ALB ───────────────────────────────────────────────────────────────────────

variable "create_alb" {
  type        = bool
  default     = true
  description = "Create an Application Load Balancer."
}

variable "alb_target_type" {
  type        = string
  description = "ALB target group target type: \"instance\" (EC2 bridge mode) or \"ip\" (Fargate awsvpc mode)."

  validation {
    condition     = contains(["instance", "ip"], var.alb_target_type)
    error_message = "alb_target_type must be \"instance\" or \"ip\"."
  }
}

variable "internal_alb" {
  type        = bool
  default     = false
  description = "Create an internal (non-internet-facing) ALB."
}

variable "allow_public_access" {
  type        = bool
  default     = true
  description = "Allow public internet access to the ALB."
}

variable "alb_certificate_arns" {
  type        = list(string)
  default     = []
  description = "ACM certificate ARNs for the HTTPS listener."
}

variable "allow_insecure_http" {
  type        = bool
  default     = false
  description = "Allow the ALB to serve plain HTTP only, that is, without alb_certificate_arns. For testing only: requests, signed URLs and tokens travel unencrypted. With CloudFront it also makes CloudFront reach the ALB over plain HTTP, so the origin secret header and all traffic cross the network in clear text."
}

variable "alb_redirect_http_to_https" {
  type        = bool
  default     = true
  description = "Redirect HTTP to HTTPS on the ALB."
}

variable "alb_idle_timeout" {
  type        = number
  default     = 60
  description = "ALB idle connection timeout in seconds."
}

variable "alb_deregistration_delay" {
  type        = number
  default     = 300
  description = "Seconds the ALB waits before deregistering a target. Must be >= alb_idle_timeout to avoid resetting in-flight connections during deployments and scale-in."
}

variable "alb_deletion_protection" {
  type        = bool
  default     = false
  description = "Enable deletion protection on the ALB."
}

# ── CloudFront ────────────────────────────────────────────────────────────────

variable "enable_cloudfront" {
  type        = bool
  default     = false
  description = "Create a CloudFront distribution in front of the ALB, or of the Lambda Function URL when compute_platform = \"lambda\"."
}

variable "cloudfront_certificate_arn" {
  type        = string
  default     = null
  description = "ACM certificate ARN for CloudFront (must be in us-east-1)."
}

variable "cloudfront_domains" {
  type        = list(string)
  default     = []
  description = "Custom domain aliases for CloudFront."
}

variable "cloudfront_origin_shield_region" {
  type        = string
  default     = null
  description = "AWS region for CloudFront Origin Shield."
}

variable "cloudfront_origin_domain" {
  type        = string
  default     = null
  description = "Domain name CloudFront uses to reach the ALB over HTTPS. It must be covered by a certificate in alb_certificate_arns and point at the ALB through a DNS record you create (an alias to the ALB). Required when enable_cloudfront = true and alb_certificate_arns is set. CloudFront validates the ALB certificate against this name, so the ALB's own DNS name cannot be used with your certificate. Must differ from cloudfront_domains."
}

variable "cloudfront_origin_verify_secret" {
  type        = string
  default     = null
  sensitive   = true
  description = "Secret sent by CloudFront in the X-Origin-Verify header; the ALB rejects requests without it. When null and CloudFront is enabled, a random secret is generated."
}

variable "cdn_default_ttl" {
  type        = number
  default     = 31536000
  description = "Default CloudFront TTL in seconds."
}

variable "cdn_min_ttl" {
  type        = number
  default     = 0
  description = "Minimum CloudFront TTL in seconds."
}

variable "cdn_max_ttl" {
  type        = number
  default     = 31556926
  description = "Maximum CloudFront TTL in seconds."
}

variable "cdn_redirect_http_to_https" {
  type        = bool
  default     = true
  description = "Redirect HTTP to HTTPS at the CloudFront viewer level."
}

variable "cdn_waf_web_acl_id" {
  type        = string
  default     = null
  description = "WAF Web ACL ARN to attach to the CloudFront distribution."
}

variable "cdn_cache_headers" {
  type        = list(string)
  default     = []
  description = "HTTP headers to include in the CloudFront cache key and forward to origin."
}

variable "cdn_cache_cookies" {
  type        = list(string)
  default     = []
  description = "Cookies to include in the CloudFront cache key and forward to origin."
}
