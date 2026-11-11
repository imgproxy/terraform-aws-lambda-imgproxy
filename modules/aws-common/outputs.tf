output "task_role_arn" {
  description = "ARN of the IAM role used by the ECS task (or Lambda function) at runtime."
  value       = var.task_role_arn != null ? var.task_role_arn : aws_iam_role.task[0].arn
}

output "execution_role_arn" {
  description = "ARN of the IAM role used by the ECS agent to start tasks. Null for compute_platform = \"lambda\"."
  value       = var.execution_role_arn != null ? var.execution_role_arn : one(aws_iam_role.execution[*].arn)
}

output "log_group_name" {
  description = "CloudWatch Log Group name."
  value       = aws_cloudwatch_log_group.main.name
}

output "log_retention_days" {
  description = "Configured CloudWatch log retention in days."
  value       = aws_cloudwatch_log_group.main.retention_in_days
}

output "alb_sg_id" {
  description = "ALB security group ID. Reference in instance or task security group rules."
  value       = length(aws_security_group.alb) > 0 ? aws_security_group.alb[0].id : null
}

output "target_group_arn" {
  description = "ALB target group ARN for the ECS service load_balancer block."
  value       = length(aws_lb_target_group.main) > 0 ? aws_lb_target_group.main[0].arn : null
}

output "alb_created" {
  description = "True when the ALB was created by this module."
  value       = length(aws_lb.main) > 0
}

output "cloudfront_created" {
  description = "True when the CloudFront distribution was created by this module."
  value       = length(aws_cloudfront_distribution.main) > 0
}

output "alb_dns_name" {
  description = "ALB DNS name."
  value       = length(aws_lb.main) > 0 ? aws_lb.main[0].dns_name : null
}

output "alb_zone_id" {
  description = "ALB hosted zone ID for Route 53 alias records."
  value       = length(aws_lb.main) > 0 ? aws_lb.main[0].zone_id : null
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name."
  value       = length(aws_cloudfront_distribution.main) > 0 ? aws_cloudfront_distribution.main[0].domain_name : null
}

output "cloudfront_distribution_arn" {
  description = "CloudFront distribution ARN."
  value       = length(aws_cloudfront_distribution.main) > 0 ? aws_cloudfront_distribution.main[0].arn : null
}

output "cloudfront_hosted_zone_id" {
  description = "CloudFront hosted zone ID for Route 53 alias records."
  value       = length(aws_cloudfront_distribution.main) > 0 ? aws_cloudfront_distribution.main[0].hosted_zone_id : null
}

output "url" {
  description = "imgproxy endpoint URL. CloudFront domain when enable_cloudfront = true, otherwise ALB DNS name."
  value = var.enable_cloudfront ? (
    length(var.cloudfront_domains) > 0
    ? "https://${var.cloudfront_domains[0]}"
    : length(aws_cloudfront_distribution.main) > 0 ? "https://${aws_cloudfront_distribution.main[0].domain_name}" : null
    ) : var.create_alb ? (
    length(var.alb_certificate_arns) > 0
    ? "https://${aws_lb.main[0].dns_name}"
    : "http://${aws_lb.main[0].dns_name}"
  ) : null
}

output "cloudfront_cache_policy_header_behavior" {
  description = "CloudFront cache policy header_behavior ('none' or 'whitelist')."
  value       = length(aws_cloudfront_cache_policy.main) > 0 ? aws_cloudfront_cache_policy.main[0].parameters_in_cache_key_and_forwarded_to_origin[0].headers_config[0].header_behavior : null
}

output "cloudfront_cache_policy_headers" {
  description = "Header names included in the CloudFront cache key."
  value       = length(aws_cloudfront_cache_policy.main) > 0 ? var.cdn_cache_headers : []
}

output "cloudfront_cache_policy_cookie_behavior" {
  description = "CloudFront cache policy cookie_behavior ('none' or 'whitelist')."
  value       = length(aws_cloudfront_cache_policy.main) > 0 ? aws_cloudfront_cache_policy.main[0].parameters_in_cache_key_and_forwarded_to_origin[0].cookies_config[0].cookie_behavior : null
}

output "cloudfront_cache_policy_cookies" {
  description = "Cookie names included in the CloudFront cache key."
  value       = length(aws_cloudfront_cache_policy.main) > 0 ? var.cdn_cache_cookies : []
}
