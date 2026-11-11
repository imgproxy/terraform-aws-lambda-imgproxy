# ── Basic Configuration ───────────────────────────────────────────────────────

variable "service_name" {
  type        = string
  default     = "imgproxy"
  description = "Prefix applied to every resource name. Also the Lambda function name unless function_name is set."
}

variable "function_name" {
  type        = string
  default     = null
  description = "Lambda function name. Defaults to service_name. The log group is /aws/lambda/<function_name>. With imgproxy Pro the name is also reported to the license server as the host name of the activation."

  validation {
    condition     = var.function_name == null || can(regex("^[a-zA-Z0-9_-]{1,64}$", var.function_name))
    error_message = "function_name must be 1-64 characters: letters, digits, hyphens and underscores."
  }
}

variable "tag" {
  type        = string
  default     = "v4"
  description = "imgproxy image tag (version). Pin a version or a sha256: digest: the image is mirrored to ECR when the tag changes, not when the upstream tag moves."
}

variable "repo" {
  type        = string
  default     = null
  description = "Container repository to mirror imgproxy from, without tag (e.g. 'registry.example.com/imgproxy'). When null, 'pro' selects docker.imgproxy.pro/imgproxy or ghcr.io/imgproxy/imgproxy. Lambda can only run images stored in ECR, so the image is copied into an ECR repository created by this module, unless repo is already an ECR repository of this account and region (<account>.dkr.ecr.<region>.amazonaws.com/...): then it is used as it is and nothing is copied. Such an image must be a single-platform image for the function's architecture, and the repository must allow Lambda to pull it (see the README)."
}

variable "repo_credentials_secret" {
  type = object({
    arn = string
  })
  default     = null
  description = "Secrets Manager secret with the credentials for the registry in 'repo' (or docker.imgproxy.pro when 'repo' is not set). Must be a JSON secret with 'username' and 'password' keys. Required when pro = true and repo is not set. Read by the machine running Terraform while mirroring the image, not by the function."
}

variable "image_uri" {
  type        = string
  default     = null
  description = "URI of an image that is already in ECR, in the same account and region. When set, nothing is mirrored and repo, tag, pro and repo_credentials_secret are ignored. Use it when the image is mirrored outside Terraform, or to pin an exact digest."
}

variable "environment" {
  type        = map(string)
  default     = {}
  description = "Additional environment variables passed to imgproxy (e.g. IMGPROXY_MAX_SRC_RESOLUTION)."
}

variable "secrets" {
  type = map(object({
    arn     = string
    version = optional(string, "")
  }))
  default     = {}
  description = "Map of environment variable names to Secrets Manager ARNs. Example: {IMGPROXY_NEW_RELIC_KEY = {arn = \"arn:aws:secretsmanager:us-east-1:123:secret:newrelic-key\"}}. Values must not contain single quotes or newlines."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to all created resources."
}

# ── Security & Signing ────────────────────────────────────────────────────────

variable "insecure" {
  type        = bool
  default     = false
  description = "Disable URL signature checks. When true, key and salt are not required."
}

variable "keys_secret" {
  type = object({
    arn     = string
    version = optional(string, "")
  })
  default     = null
  description = "Secrets Manager ARN for imgproxy signing keys (comma-separated hex-encoded values). Required when insecure = false. Generate: openssl rand -hex 64. Sets IMGPROXY_KEY."
}

variable "salts_secret" {
  type = object({
    arn     = string
    version = optional(string, "")
  })
  default     = null
  description = "Secrets Manager ARN for imgproxy signing salts (must match number of keys). Required when insecure = false. Sets IMGPROXY_SALT."
}

variable "secret_secret" {
  type = object({
    arn     = string
    version = optional(string, "")
  })
  default     = null
  description = "Secrets Manager ARN for the authorization token. When set, requests must include Authorization: Bearer <token>. Sets IMGPROXY_SECRET."
}

variable "signature_size" {
  type        = number
  default     = 32
  description = "Number of bytes from the key/salt used for signing. Sets IMGPROXY_SIGNATURE_SIZE."
}

variable "trusted_signatures_secret" {
  type = object({
    arn     = string
    version = optional(string, "")
  })
  default     = null
  description = "Secrets Manager ARN for trusted signature prefixes. imgproxy Pro only. Sets IMGPROXY_TRUSTED_SIGNATURES."
}

variable "source_url_encryption_key_secret" {
  type = object({
    arn     = string
    version = optional(string, "")
  })
  default     = null
  description = "Secrets Manager ARN for the source URL encryption key. Sets IMGPROXY_SOURCE_URL_ENCRYPTION_KEY."
}

# ── Compute Resources ─────────────────────────────────────────────────────────

variable "architecture" {
  type        = string
  default     = "arm64"
  description = "Instruction set architecture of the function. arm64 (Graviton) is recommended: lower cost, same performance. The matching image platform is mirrored."

  validation {
    condition     = contains(["arm64", "x86_64"], var.architecture)
    error_message = "architecture must be arm64 or x86_64."
  }
}

variable "memory_size" {
  type        = number
  default     = 2048
  description = "Memory in MB (128–10240). Lambda allocates CPU in proportion: about 1 vCPU per 1769 MB."

  validation {
    condition     = var.memory_size >= 128 && var.memory_size <= 10240
    error_message = "memory_size must be between 128 and 10240."
  }
}

variable "ephemeral_storage_size" {
  type        = number
  default     = 512
  description = "Size of the function's /tmp in MB (512–10240)."

  validation {
    condition     = var.ephemeral_storage_size >= 512 && var.ephemeral_storage_size <= 10240
    error_message = "ephemeral_storage_size must be between 512 and 10240."
  }
}

variable "function_timeout" {
  type        = number
  default     = 30
  description = "Lambda function timeout in seconds (1–900)."

  validation {
    condition     = var.function_timeout >= 1 && var.function_timeout <= 900
    error_message = "function_timeout must be between 1 and 900."
  }
}

variable "workers" {
  type        = number
  default     = null
  description = "Number of concurrent requests per function instance. Sets IMGPROXY_WORKERS. Defaults to 1: Lambda hands one request at a time to each instance."
}

variable "timeout" {
  type        = number
  default     = null
  description = "imgproxy request timeout in seconds. Sets IMGPROXY_TIMEOUT. Keep it below function_timeout."
}

# ── Storage Integration ───────────────────────────────────────────────────────

variable "source_buckets" {
  type        = list(string)
  default     = []
  description = "S3 bucket names for imgproxy source images. The function role is granted s3:GetObject, s3:GetObjectVersion and s3:ListBucket on each. Enables IMGPROXY_USE_S3."
}

variable "cache_bucket" {
  type        = string
  default     = null
  description = "S3 bucket name for imgproxy result cache (imgproxy Pro only). The function role is granted full object access."
}

# ── Scaling ───────────────────────────────────────────────────────────────────

variable "reserved_concurrency" {
  type        = number
  default     = null
  description = "Maximum concurrent executions of the function (reserved concurrency). When null, the function draws on the account's unreserved pool. Set it to cap cost and protect the account limit."
}

variable "provisioned_concurrency" {
  type        = number
  default     = 0
  description = "Number of pre-initialized instances kept warm, which removes cold starts for that many concurrent requests. When above 0, the function is published to a 'live' alias and the Function URL points at the alias. Billed continuously."

  validation {
    condition     = var.provisioned_concurrency >= 0
    error_message = "provisioned_concurrency must not be negative."
  }
}

# ── imgproxy Pro ──────────────────────────────────────────────────────────────

variable "pro" {
  type        = bool
  default     = false
  description = "Use imgproxy Pro (docker.imgproxy.pro) instead of the community image (ghcr.io) as the default repo. Has no effect when repo or image_uri is set."
}

variable "pro_license_key_secret" {
  type = object({
    arn     = string
    version = optional(string, "")
  })
  default     = null
  description = "Secrets Manager ARN for the imgproxy Pro license key. Sets IMGPROXY_LICENSE_KEY."
}

# ── Observability & Monitoring ────────────────────────────────────────────────

variable "enable_monitoring" {
  type        = bool
  default     = false
  description = "Enable X-Ray active tracing and imgproxy's CloudWatch metrics (namespace 'imgproxy'), and grant the function role the matching permissions."
}

variable "log_retention_days" {
  type        = number
  default     = 365
  description = "CloudWatch log group retention in days."
}

# ── Networking ────────────────────────────────────────────────────────────────

variable "vpc_id" {
  type        = string
  default     = null
  description = "VPC ID to attach the function to. Only needed to reach private resources: the function then loses internet access unless the subnets route through a NAT gateway or VPC endpoints for S3 and Secrets Manager. When null, the function runs outside any VPC."
}

variable "subnet_ids" {
  type        = list(string)
  default     = []
  description = "Subnet IDs for the function ENIs. Required when vpc_id is set; use private subnets."
}

variable "additional_security_group_ids" {
  type        = list(string)
  default     = []
  description = "Additional security group IDs to attach to the function."
}

# ── Function URL ──────────────────────────────────────────────────────────────

variable "allow_public_access" {
  type        = bool
  default     = true
  description = "Make the Function URL publicly callable (authorization NONE). When false, callers must sign requests with SigV4 (authorization AWS_IAM). Ignored when enable_cloudfront = true: CloudFront is then the only caller."
}

# ── CloudFront CDN ────────────────────────────────────────────────────────────

variable "enable_cloudfront" {
  type        = bool
  default     = false
  description = "Create a CloudFront distribution in front of the Function URL for global edge caching. The Function URL then accepts only requests signed by this distribution (Origin Access Control)."
}

variable "cloudfront_certificate_arn" {
  type        = string
  default     = null
  description = "ACM certificate ARN for CloudFront (must be in us-east-1). Required when cloudfront_domains is set."
}

variable "cloudfront_domains" {
  type        = list(string)
  default     = []
  description = "Custom domain aliases for the CloudFront distribution. Requires cloudfront_certificate_arn."
}

variable "cloudfront_origin_shield_region" {
  type        = string
  default     = null
  description = "AWS region to enable CloudFront Origin Shield (e.g. \"us-east-1\"). Adds an extra caching tier between edge locations and the function, reducing invocations. When null, Origin Shield is disabled."
}

variable "cdn_default_ttl" {
  type        = number
  default     = 31536000
  description = "Default CloudFront TTL in seconds. Set to 0 to let CloudFront respect origin Cache-Control headers."
}

variable "cdn_min_ttl" {
  type        = number
  default     = 0
  description = "Minimum CloudFront TTL in seconds. Set to a positive value to force a floor TTL regardless of origin headers."
}

variable "cdn_max_ttl" {
  type        = number
  default     = 31556926
  description = "Maximum CloudFront TTL in seconds, regardless of origin headers."
}

variable "cdn_redirect_http_to_https" {
  type        = bool
  default     = true
  description = "Redirect HTTP to HTTPS at the CloudFront level."
}

variable "cdn_waf_web_acl_id" {
  type        = string
  default     = null
  description = "WAF Web ACL ARN to associate with the CloudFront distribution."
}

# ── IAM ───────────────────────────────────────────────────────────────────────

variable "role_arn" {
  type        = string
  default     = null
  description = "ARN of an existing IAM role to use as the function role. When null, a role is created with logging, S3, Secrets Manager and monitoring permissions as needed. A custom role needs those permissions itself (and the VPC access policy when vpc_id is set)."
}
