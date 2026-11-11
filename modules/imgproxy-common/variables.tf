# Image Configuration
variable "tag" {
  type        = string
  description = "imgproxy image tag (version) or a sha256: digest. Must not be empty. \"latest\" is allowed but discouraged."

  validation {
    condition     = length(trimspace(var.tag)) > 0
    error_message = "tag must be a non-empty version tag or sha256: digest."
  }
}

variable "repo" {
  type        = string
  description = "Container repository (without tag or digest) the image is pulled from."
}

# Compute Configuration
variable "cpu" {
  type        = number
  description = "CPU allocation for the container."

  validation {
    condition     = var.cpu > 0
    error_message = "cpu must be greater than 0."
  }
}

variable "workers" {
  type        = number
  default     = null
  description = "Number of workers. When null, calculated as ceil(cpu * 2)."
}

variable "timeout" {
  type        = number
  default     = null
  description = "Request timeout in seconds."

  validation {
    condition     = var.timeout == null ? true : var.timeout > 0
    error_message = "timeout must be greater than 0 when set."
  }
}

variable "signature_size" {
  type        = number
  default     = 32
  description = "Number of bytes from the key/salt used for signing (1-32)."

  validation {
    condition     = var.signature_size >= 1 && var.signature_size <= 32
    error_message = "signature_size must be between 1 and 32."
  }
}

# Environment Variables
variable "environment" {
  type        = map(string)
  default     = {}
  description = "Additional environment variables passed to imgproxy. Merged last, so they override the computed ones."
}

# Provider-Specific Configuration
variable "secret_key_name" {
  type        = string
  description = "Key name for secret references ('id' for Azure, 'secret' for GCP)."
}

variable "storage_env_key" {
  type        = string
  default     = null
  description = "Environment variable key for storage ('IMGPROXY_USE_ABS' for Azure, 'IMGPROXY_USE_GCS' for GCP). Required when storage_enabled = true."
}

variable "storage_enabled" {
  type        = bool
  default     = false
  description = "Whether storage is enabled."
}

variable "enable_monitoring" {
  type        = bool
  default     = false
  description = "Whether OpenTelemetry environment variables should be configured for imgproxy."
}

variable "otel_service_name" {
  type        = string
  default     = "imgproxy"
  description = "Service name exposed to OpenTelemetry when monitoring is enabled."
}

variable "otel_exporter_endpoint" {
  type        = string
  default     = "http://localhost:4318"
  description = "OTLP endpoint imgproxy exports to when monitoring is enabled."
}

# Security & Secrets
variable "insecure" {
  type        = bool
  default     = false
  description = "Disable URL signature checks."
}

variable "secrets" {
  type = map(object({
    id      = string
    version = string
  }))
  default     = {}
  description = "Map of environment variable names to secret references. Merged last, so entries override the dedicated *_secret variables."
}

variable "keys_secret" {
  type = object({
    id      = string
    version = string
  })
  default     = null
  description = "Secret reference for imgproxy signing keys. Required together with salts_secret unless insecure = true."
}

variable "salts_secret" {
  type = object({
    id      = string
    version = string
  })
  default     = null
  description = "Secret reference for imgproxy signing salts. Required together with keys_secret unless insecure = true."
}

variable "secret_secret" {
  type = object({
    id      = string
    version = string
  })
  default     = null
  description = "Secret reference for authorization token."
}

variable "trusted_signatures_secret" {
  type = object({
    id      = string
    version = string
  })
  default     = null
  description = "Secret reference for trusted signature prefixes."
}

variable "source_url_encryption_key_secret" {
  type = object({
    id      = string
    version = string
  })
  default     = null
  description = "Secret reference for source URL encryption key."
}

variable "pro_license_key_secret" {
  type = object({
    id      = string
    version = string
  })
  default     = null
  description = "Secret reference for imgproxy Pro license key."
}
