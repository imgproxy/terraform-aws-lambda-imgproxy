data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  is_lambda     = var.compute_platform == "lambda"
  alb_subnets   = coalesce(var.alb_subnet_ids, var.subnet_ids)
  http_redirect = var.alb_redirect_http_to_https && length(var.alb_certificate_arns) > 0
  # HTTPS to the origin needs a name the ALB certificate covers; without one CloudFront
  # falls back to plain HTTP, which is only allowed with allow_insecure_http.
  cf_origin_https    = var.cloudfront_origin_domain != null
  cf_origin_protocol = local.cf_origin_https ? "https-only" : "http-only"

  # The CloudFront prefix list admits every CloudFront distribution, not just
  # ours, so the ALB also requires this secret header when CloudFront is used.
  cf_locked_origin     = var.enable_cloudfront && var.create_alb
  origin_verify_header = "X-Origin-Verify"
  origin_verify_secret = local.cf_locked_origin ? coalesce(var.cloudfront_origin_verify_secret, one(random_password.origin_verify[*].result)) : null

  # Lambda Function URL origin: CloudFront signs requests (OAC) instead of sending
  # a secret header, and reaches the function URL host over HTTPS.
  cf_lambda_origin = var.enable_cloudfront && local.is_lambda
  lambda_url_host  = var.lambda_function_url != null ? split("/", var.lambda_function_url)[2] : null
}

resource "random_password" "origin_verify" {
  count   = local.cf_locked_origin && var.cloudfront_origin_verify_secret == null ? 1 : 0
  length  = 32
  special = false
}

# Cross-variable checks that a single variable validation cannot express.
resource "terraform_data" "checks" {
  lifecycle {
    precondition {
      condition     = !local.is_lambda || !var.create_alb
      error_message = "compute_platform = \"lambda\" does not use an ALB: set create_alb = false."
    }

    precondition {
      condition     = !local.cf_lambda_origin || var.lambda_function_url != null
      error_message = "lambda_function_url is required when compute_platform = \"lambda\" and enable_cloudfront = true."
    }

    precondition {
      condition     = !var.create_alb || length(var.alb_certificate_arns) > 0 || var.allow_insecure_http
      error_message = "The ALB needs HTTPS: set alb_certificate_arns. To serve plain HTTP for testing only, set allow_insecure_http = true (requests, signed URLs and tokens are then unencrypted)."
    }

    precondition {
      condition     = !local.cf_locked_origin || length(var.alb_certificate_arns) == 0 || var.cloudfront_origin_domain != null
      error_message = "cloudfront_origin_domain is required when enable_cloudfront = true and alb_certificate_arns is set: CloudFront validates the ALB certificate against the origin domain name, which cannot be the ALB's own DNS name."
    }

    precondition {
      condition     = var.cloudfront_origin_domain == null || (local.cf_locked_origin && length(var.alb_certificate_arns) > 0)
      error_message = "cloudfront_origin_domain requires enable_cloudfront = true, create_alb = true and alb_certificate_arns covering that domain."
    }

    precondition {
      condition     = var.cloudfront_origin_domain == null ? true : !contains(var.cloudfront_domains, var.cloudfront_origin_domain)
      error_message = "cloudfront_origin_domain must differ from cloudfront_domains: the origin domain points at the ALB, the CloudFront domains point at CloudFront."
    }
  }
}

# Fetch the managed prefix list for CloudFront origin-facing IPs so the ALB can
# restrict ingress to CloudFront only when enable_cloudfront = true.
data "aws_ec2_managed_prefix_list" "cloudfront" {
  count = var.enable_cloudfront && var.create_alb ? 1 : 0
  name  = "com.amazonaws.global.cloudfront.origin-facing"
}

# ── IAM: task execution role ──────────────────────────────────────────────────
# Used by the ECS agent to pull the container image and inject secrets at startup.

resource "aws_iam_role" "execution" {
  count       = var.execution_role_arn == null && !local.is_lambda ? 1 : 0
  name_prefix = "${var.service_name}-execution-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  count      = var.execution_role_arn == null && !local.is_lambda ? 1 : 0
  role       = aws_iam_role.execution[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secrets" {
  count = var.execution_role_arn == null && !local.is_lambda && length(var.secret_arns) > 0 ? 1 : 0
  name  = "${var.service_name}-secrets"
  role  = aws_iam_role.execution[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = var.secret_arns
    }]
  })
}

# ── IAM: task role ────────────────────────────────────────────────────────────
# Used by the running imgproxy container for S3 access and monitoring.

resource "aws_iam_role" "task" {
  count       = var.task_role_arn == null ? 1 : 0
  name_prefix = local.is_lambda ? "${var.service_name}-function-" : "${var.service_name}-task-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [merge(
      {
        Effect    = "Allow"
        Principal = { Service = local.is_lambda ? "lambda.amazonaws.com" : "ecs-tasks.amazonaws.com" }
        Action    = "sts:AssumeRole"
      },
      local.is_lambda ? {} : {
        Condition = {
          ArnLike = {
            "aws:SourceArn" = "arn:aws:ecs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*"
          }
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
    )]
  })

  tags = var.tags
}

# Lambda only: CloudWatch Logs access, plus ENI management when attached to a VPC.
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  count      = var.task_role_arn == null && local.is_lambda ? 1 : 0
  role       = aws_iam_role.task[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  count      = var.task_role_arn == null && local.is_lambda && var.lambda_vpc_access ? 1 : 0
  role       = aws_iam_role.task[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Lambda only: imgproxy reads its secrets itself at start-up (IMGPROXY_ENV_AWS_SECRET_ID),
# so the function role, not an execution role, needs access to them.
resource "aws_iam_role_policy" "task_secrets" {
  count = var.task_role_arn == null && local.is_lambda && length(var.secret_arns) > 0 ? 1 : 0
  name  = "${var.service_name}-secrets"
  role  = aws_iam_role.task[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = var.secret_arns
    }]
  })
}

resource "aws_iam_role_policy" "task_s3_source" {
  count = var.task_role_arn == null && length(var.source_buckets) > 0 ? 1 : 0
  name  = "${var.service_name}-s3-source"
  role  = aws_iam_role.task[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = [for b in var.source_buckets : "arn:aws:s3:::${b}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [for b in var.source_buckets : "arn:aws:s3:::${b}"]
      },
    ]
  })
}

resource "aws_iam_role_policy" "task_s3_cache" {
  count = var.task_role_arn == null && var.cache_bucket != null ? 1 : 0
  name  = "${var.service_name}-s3-cache"
  role  = aws_iam_role.task[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::${var.cache_bucket}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${var.cache_bucket}"
      },
    ]
  })
}

resource "aws_iam_role_policy" "task_monitoring" {
  count = var.task_role_arn == null && var.enable_monitoring ? 1 : 0
  name  = "${var.service_name}-monitoring"
  role  = aws_iam_role.task[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "xray:PutTraceSegments",
        "xray:PutTelemetryRecords",
        "xray:GetSamplingRules",
        "xray:GetSamplingTargets",
        "cloudwatch:PutMetricData",
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams",
      ]
      Resource = "*"
    }]
  })
}

# Always grant PutMetricData for the imgproxy namespace so autoscaling alarms
# receive WorkersUtilization data regardless of enable_monitoring.
resource "aws_iam_role_policy" "task_autoscaling_metrics" {
  count = var.task_role_arn == null && !local.is_lambda ? 1 : 0
  name  = "${var.service_name}-autoscaling-metrics"
  role  = aws_iam_role.task[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "cloudwatch:PutMetricData"
      Resource = "*"
      Condition = {
        StringEquals = {
          "cloudwatch:namespace" = "imgproxy"
        }
      }
    }]
  })
}

# ── CloudWatch Log Group ──────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "main" {
  name              = coalesce(var.log_group_name, "/aws/ecs/${var.service_name}")
  retention_in_days = var.log_retention_days
  tags              = var.tags
}



# ── ALB Security Group ────────────────────────────────────────────────────────

resource "aws_security_group" "alb" {
  count       = var.create_alb ? 1 : 0
  name_prefix = "${var.service_name}-alb-"
  vpc_id      = var.vpc_id
  description = "${var.service_name} ALB"

  # Direct public access (no CloudFront)
  dynamic "ingress" {
    for_each = var.allow_public_access && !var.enable_cloudfront ? [80] : []
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  # When CloudFront is enabled, restrict the origin port to CloudFront origin IPs
  # only. Only the port CloudFront uses is opened (80 for http-only origins, 443
  # for https-only): the prefix list counts as ~55 rules against the default
  # limit of 60 rules per security group, so it can't be referenced twice.
  dynamic "ingress" {
    for_each = var.enable_cloudfront && length(var.alb_certificate_arns) == 0 ? [80] : []
    content {
      from_port       = ingress.value
      to_port         = ingress.value
      protocol        = "tcp"
      prefix_list_ids = data.aws_ec2_managed_prefix_list.cloudfront[*].id
      description     = "CloudFront origin-facing"
    }
  }

  dynamic "ingress" {
    for_each = var.allow_public_access && !var.enable_cloudfront && length(var.alb_certificate_arns) > 0 ? [443] : []
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  dynamic "ingress" {
    for_each = var.enable_cloudfront && length(var.alb_certificate_arns) > 0 ? [443] : []
    content {
      from_port       = ingress.value
      to_port         = ingress.value
      protocol        = "tcp"
      prefix_list_ids = data.aws_ec2_managed_prefix_list.cloudfront[*].id
      description     = "CloudFront origin-facing HTTPS"
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.service_name}-alb" })

  lifecycle {
    create_before_destroy = true
  }
}

# ── Application Load Balancer ─────────────────────────────────────────────────

resource "aws_lb" "main" {
  count              = var.create_alb ? 1 : 0
  name_prefix        = substr(var.service_name, 0, 6)
  internal           = var.internal_alb
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb[0].id]
  subnets            = local.alb_subnets
  idle_timeout       = var.alb_idle_timeout

  drop_invalid_header_fields = true

  enable_deletion_protection = var.alb_deletion_protection

  tags = merge(var.tags, { Name = var.service_name })
}

resource "aws_lb_target_group" "main" {
  count       = var.create_alb ? 1 : 0
  name_prefix = substr(var.service_name, 0, 6)
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = var.alb_target_type

  load_balancing_algorithm_type = "least_outstanding_requests"
  deregistration_delay          = var.alb_deregistration_delay

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 10
    timeout             = 5
    matcher             = "200"
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "http" {
  count             = var.create_alb ? 1 : 0
  load_balancer_arn = aws_lb.main[0].arn
  port              = 80
  protocol          = "HTTP"

  # Wait for CloudFront to deploy the origin header before the listener starts
  # rejecting requests without it, so upgrades need no manual ordering.
  depends_on = [aws_cloudfront_distribution.main]

  default_action {
    type             = local.http_redirect ? "redirect" : local.cf_locked_origin ? "fixed-response" : "forward"
    target_group_arn = local.http_redirect || local.cf_locked_origin ? null : aws_lb_target_group.main[0].arn

    dynamic "redirect" {
      for_each = local.http_redirect ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }

    dynamic "fixed_response" {
      for_each = !local.http_redirect && local.cf_locked_origin ? [1] : []
      content {
        content_type = "text/plain"
        message_body = "Forbidden"
        status_code  = "403"
      }
    }
  }

  tags = var.tags
}

resource "aws_lb_listener_rule" "http_origin_verify" {
  count        = local.cf_locked_origin && !local.http_redirect ? 1 : 0
  listener_arn = aws_lb_listener.http[0].arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main[0].arn
  }

  condition {
    http_header {
      http_header_name = local.origin_verify_header
      values           = [local.origin_verify_secret]
    }
  }
}

resource "aws_lb_listener" "https" {
  count             = var.create_alb && length(var.alb_certificate_arns) > 0 ? 1 : 0
  load_balancer_arn = aws_lb.main[0].arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.alb_certificate_arns[0]

  # Wait for CloudFront to deploy the origin header before the listener starts
  # rejecting requests without it, so upgrades need no manual ordering.
  depends_on = [aws_cloudfront_distribution.main]

  default_action {
    type             = local.cf_locked_origin ? "fixed-response" : "forward"
    target_group_arn = local.cf_locked_origin ? null : aws_lb_target_group.main[0].arn

    dynamic "fixed_response" {
      for_each = local.cf_locked_origin ? [1] : []
      content {
        content_type = "text/plain"
        message_body = "Forbidden"
        status_code  = "403"
      }
    }
  }

  tags = var.tags
}

resource "aws_lb_listener_rule" "https_origin_verify" {
  count        = local.cf_locked_origin && length(var.alb_certificate_arns) > 0 ? 1 : 0
  listener_arn = aws_lb_listener.https[0].arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main[0].arn
  }

  condition {
    http_header {
      http_header_name = local.origin_verify_header
      values           = [local.origin_verify_secret]
    }
  }
}

resource "aws_lb_listener_certificate" "https_extra" {
  for_each        = var.create_alb && length(var.alb_certificate_arns) > 1 ? toset(slice(var.alb_certificate_arns, 1, length(var.alb_certificate_arns))) : toset([])
  listener_arn    = aws_lb_listener.https[0].arn
  certificate_arn = each.value
}

# ── CloudFront CDN ────────────────────────────────────────────────────────────

resource "aws_cloudfront_cache_policy" "main" {
  count = var.enable_cloudfront ? 1 : 0
  name  = var.service_name

  min_ttl     = var.cdn_min_ttl
  default_ttl = var.cdn_default_ttl
  max_ttl     = var.cdn_max_ttl

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true

    headers_config {
      header_behavior = length(var.cdn_cache_headers) > 0 ? "whitelist" : "none"
      dynamic "headers" {
        for_each = length(var.cdn_cache_headers) > 0 ? [1] : []
        content {
          items = var.cdn_cache_headers
        }
      }
    }

    cookies_config {
      cookie_behavior = length(var.cdn_cache_cookies) > 0 ? "whitelist" : "none"
      dynamic "cookies" {
        for_each = length(var.cdn_cache_cookies) > 0 ? [1] : []
        content {
          items = var.cdn_cache_cookies
        }
      }
    }

    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

resource "aws_cloudfront_origin_access_control" "lambda" {
  count = local.cf_lambda_origin ? 1 : 0

  name                              = var.service_name
  description                       = "${var.service_name} Lambda Function URL"
  origin_access_control_origin_type = "lambda"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "main" {
  count = var.enable_cloudfront && (var.create_alb || local.is_lambda) ? 1 : 0

  origin {
    domain_name              = local.cf_lambda_origin ? local.lambda_url_host : coalesce(var.cloudfront_origin_domain, aws_lb.main[0].dns_name)
    origin_id                = local.cf_lambda_origin ? "lambda" : "alb"
    origin_access_control_id = local.cf_lambda_origin ? aws_cloudfront_origin_access_control.lambda[0].id : null

    dynamic "custom_header" {
      for_each = local.cf_lambda_origin ? [] : [1]
      content {
        name  = local.origin_verify_header
        value = local.origin_verify_secret
      }
    }

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = local.cf_lambda_origin ? "https-only" : local.cf_origin_protocol
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    dynamic "origin_shield" {
      for_each = var.cloudfront_origin_shield_region != null ? [1] : []
      content {
        enabled              = true
        origin_shield_region = var.cloudfront_origin_shield_region
      }
    }
  }

  enabled         = true
  is_ipv6_enabled = true
  http_version    = "http2and3"
  comment         = "${var.service_name} imgproxy"
  aliases         = var.cloudfront_domains

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = local.cf_lambda_origin ? "lambda" : "alb"
    viewer_protocol_policy = var.cdn_redirect_http_to_https ? "redirect-to-https" : "allow-all"
    cache_policy_id        = aws_cloudfront_cache_policy.main[0].id
    compress               = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn            = var.cloudfront_certificate_arn
    cloudfront_default_certificate = var.cloudfront_certificate_arn == null
    ssl_support_method             = var.cloudfront_certificate_arn != null ? "sni-only" : null
    minimum_protocol_version       = var.cloudfront_certificate_arn != null ? "TLSv1.2_2021" : "TLSv1"
  }

  web_acl_id = var.cdn_waf_web_acl_id

  tags = var.tags
}
