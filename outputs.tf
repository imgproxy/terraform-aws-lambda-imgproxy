output "url" {
  description = "imgproxy endpoint URL. CloudFront domain when enable_cloudfront = true, otherwise the Function URL."
  value       = var.enable_cloudfront ? module.aws_common.url : trimsuffix(aws_lambda_function_url.main.function_url, "/")
}

output "function_name" {
  description = "Lambda function name."
  value       = aws_lambda_function.main.function_name
}

output "function_arn" {
  description = "Lambda function ARN."
  value       = aws_lambda_function.main.arn
}

output "function_url" {
  description = "Lambda Function URL (the origin behind CloudFront when enabled)."
  value       = aws_lambda_function_url.main.function_url
}

output "image_uri" {
  description = "ECR image the function runs."
  value       = local.image_uri
}

output "role_arn" {
  description = "ARN of the IAM role used by the function at runtime."
  value       = module.aws_common.task_role_arn
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name."
  value       = module.aws_common.cloudfront_domain_name
}

output "cloudfront_hosted_zone_id" {
  description = "CloudFront hosted zone ID. Use with Route 53 alias records."
  value       = module.aws_common.cloudfront_hosted_zone_id
}

output "security_group_id" {
  description = "Security group ID attached to the function (null when not attached to a VPC)."
  value       = one(aws_security_group.function[*].id)
}

output "log_group_name" {
  description = "CloudWatch Log Group name for imgproxy logs."
  value       = module.aws_common.log_group_name
}
