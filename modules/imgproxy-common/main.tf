locals {
  # Image reference construction
  ref   = startswith(var.tag, "sha256:") ? "@${var.tag}" : ":${var.tag}"
  image = "${var.repo}${local.ref}"

  # Workers calculation (must be integer for IMGPROXY_WORKERS env var)
  workers = var.workers != null ? var.workers : ceil(var.cpu * 2)

  # Environment variables merge
  env_vars = merge(
    { IMGPROXY_SIGNATURE_SIZE = tostring(var.signature_size) },
    { IMGPROXY_WORKERS = tostring(local.workers) },
    var.timeout != null ? { IMGPROXY_TIMEOUT = tostring(var.timeout) } : {},
    var.enable_monitoring ? {
      IMGPROXY_OPEN_TELEMETRY_ENABLE         = "true"
      IMGPROXY_OPEN_TELEMETRY_ENABLE_METRICS = "true"
      IMGPROXY_OPEN_TELEMETRY_ENABLE_LOGS    = "false"
      OTEL_EXPORTER_OTLP_ENDPOINT            = var.otel_exporter_endpoint
      OTEL_EXPORTER_OTLP_PROTOCOL            = "http/protobuf"
      OTEL_SERVICE_NAME                      = var.otel_service_name
    } : {},
    var.storage_enabled && var.storage_env_key != null ? { (var.storage_env_key) = "true" } : {},
    var.environment,
  )

  # CDN cache key derivation from imgproxy env vars
  truthy = toset(["1", "t", "T", "TRUE", "true", "True"])

  # Comma-separated imgproxy settings parsed into trimmed, non-empty lists
  cache_key_lists = {
    for k in ["IMGPROXY_CACHE_KEY_HEADERS", "IMGPROXY_CACHE_KEY_COOKIES"] :
    k => compact([for v in split(",", lookup(var.environment, k, "")) : trimspace(v)])
  }

  format_detect_keys = [
    "IMGPROXY_AUTO_WEBP", "IMGPROXY_AUTO_AVIF", "IMGPROXY_AUTO_JXL",
    "IMGPROXY_ENFORCE_WEBP", "IMGPROXY_ENFORCE_AVIF", "IMGPROXY_ENFORCE_JXL",
  ]
  cdn_include_accept       = anytrue([for k in local.format_detect_keys : contains(local.truthy, lookup(var.environment, k, ""))])
  cdn_include_client_hints = contains(local.truthy, lookup(var.environment, "IMGPROXY_ENABLE_CLIENT_HINTS", ""))

  cdn_header_candidates = compact(concat(
    local.cdn_include_accept ? ["Accept"] : [],
    local.cdn_include_client_hints ? ["Sec-Ch-Dpr", "Dpr", "Sec-Ch-Width", "Width"] : [],
    local.cache_key_lists["IMGPROXY_CACHE_KEY_HEADERS"],
  ))
  # HTTP header names are case-insensitive and CloudFront rejects duplicates,
  # so keep the first spelling of each.
  cdn_header_candidates_lower = [for h in local.cdn_header_candidates : lower(h)]
  cdn_cache_headers = [
    for i, h in local.cdn_header_candidates : h
    if !contains(slice(local.cdn_header_candidates_lower, 0, i), local.cdn_header_candidates_lower[i])
  ]
  cdn_cache_cookies = local.cache_key_lists["IMGPROXY_CACHE_KEY_COOKIES"]

  # Secret variables (parameterized key name: "id" vs "secret").
  # Signing key and salt are skipped when insecure; null entries are dropped.
  named_secrets = {
    IMGPROXY_KEY                       = var.insecure ? null : var.keys_secret
    IMGPROXY_SALT                      = var.insecure ? null : var.salts_secret
    IMGPROXY_SECRET                    = var.secret_secret
    IMGPROXY_TRUSTED_SIGNATURES        = var.trusted_signatures_secret
    IMGPROXY_SOURCE_URL_ENCRYPTION_KEY = var.source_url_encryption_key_secret
    IMGPROXY_LICENSE_KEY               = var.pro_license_key_secret
  }

  # var.secrets is merged last, so it overrides the named secrets above.
  env_secret_vars = {
    for k, v in merge({ for k, v in local.named_secrets : k => v if v != null }, var.secrets) :
    k => { (var.secret_key_name) = v.id, version = v.version }
  }
}

# Cross-variable checks that a single variable validation cannot express.
resource "terraform_data" "checks" {
  lifecycle {
    precondition {
      condition     = var.insecure || (var.keys_secret != null && var.salts_secret != null)
      error_message = "keys_secret and salts_secret must both be set unless insecure = true; otherwise imgproxy would run without URL signature checks."
    }

    precondition {
      condition     = !var.storage_enabled || var.storage_env_key != null
      error_message = "storage_env_key must be set when storage_enabled = true."
    }

    precondition {
      condition     = !var.enable_monitoring || var.otel_service_name != null
      error_message = "otel_service_name must not be null when enable_monitoring = true."
    }
  }
}

# Warning only: "latest" is valid but makes deployments non-reproducible.
check "latest_tag" {
  assert {
    condition     = lower(trimspace(var.tag)) != "latest"
    error_message = "tag \"latest\" is not recommended; pin a version or a sha256: digest for reproducible deployments."
  }
}
