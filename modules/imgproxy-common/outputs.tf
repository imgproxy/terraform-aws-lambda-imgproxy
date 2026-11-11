output "image" {
  value       = local.image
  description = "Full container image reference."
}

output "workers" {
  value       = local.workers
  description = "Computed number of workers."
}

output "env_vars" {
  value       = local.env_vars
  description = "Merged environment variables map."
}

output "cdn_cache_headers" {
  value       = local.cdn_cache_headers
  description = "HTTP headers to include in the CDN cache key, derived from imgproxy env vars."
}

output "cdn_cache_cookies" {
  value       = local.cdn_cache_cookies
  description = "Cookies to include in the CDN cache key, derived from IMGPROXY_CACHE_KEY_COOKIES."
}

output "env_secret_vars" {
  value       = local.env_secret_vars
  description = "Secret environment variables in provider-specific format."
}
