data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  function_name = coalesce(var.function_name, var.service_name)

  # Image repository: `repo` when set, otherwise the default selected by `pro`
  image_repo = var.repo != null ? var.repo : (var.pro ? "docker.imgproxy.pro/imgproxy" : "ghcr.io/imgproxy/imgproxy")
}

module "imgproxy_common" {
  source = "./modules/imgproxy-common"

  tag  = var.tag
  repo = local.image_repo

  cpu            = local.vcpus
  workers        = coalesce(var.workers, 1)
  timeout        = var.timeout
  signature_size = var.signature_size

  secret_key_name = "arn"
  storage_env_key = "IMGPROXY_USE_S3"
  storage_enabled = length(var.source_buckets) > 0

  insecure    = var.insecure
  environment = var.environment
  secrets     = { for k, v in var.secrets : k => { id = v.arn, version = v.version } }

  keys_secret                      = var.keys_secret != null ? { id = var.keys_secret.arn, version = var.keys_secret.version } : null
  salts_secret                     = var.salts_secret != null ? { id = var.salts_secret.arn, version = var.salts_secret.version } : null
  secret_secret                    = var.secret_secret != null ? { id = var.secret_secret.arn, version = var.secret_secret.version } : null
  trusted_signatures_secret        = var.trusted_signatures_secret != null ? { id = var.trusted_signatures_secret.arn, version = var.trusted_signatures_secret.version } : null
  source_url_encryption_key_secret = var.source_url_encryption_key_secret != null ? { id = var.source_url_encryption_key_secret.arn, version = var.source_url_encryption_key_secret.version } : null
  pro_license_key_secret           = var.pro_license_key_secret != null ? { id = var.pro_license_key_secret.arn, version = var.pro_license_key_secret.version } : null
}

locals {
  env_vars        = module.imgproxy_common.env_vars
  env_secret_vars = module.imgproxy_common.env_secret_vars

  # Lambda allocates about one vCPU per 1769 MB of memory.
  vcpus = var.memory_size / 1769

  cloudwatch_env_vars = var.enable_monitoring ? {
    IMGPROXY_CLOUD_WATCH_SERVICE_NAME = var.service_name
    IMGPROXY_CLOUD_WATCH_NAMESPACE    = "imgproxy"
    IMGPROXY_CLOUD_WATCH_REGION       = data.aws_region.current.region
  } : {}

  platform = var.architecture == "arm64" ? "linux/arm64" : "linux/amd64"
  # A repo that is already in this account's ECR, in this region, is used as it is: nothing is
  # copied and no repository is created. Any other repo is mirrored into an ECR repository of its own.
  repo_in_ecr = var.repo == null ? false : startswith(var.repo, "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.region}.amazonaws.com/")
  mirror      = var.image_uri == null && !local.repo_in_ecr
  use_alias   = var.provisioned_concurrency > 0
  use_vpc     = var.vpc_id != null
  use_secret  = length(local.env_secret_vars) > 0

  # ECR tags cannot contain ':' (digest tags become sha256-<hex>).
  mirror_tag = replace(var.tag, ":", "-")

  # CloudFront signs its requests (OAC), so the URL is IAM-protected when it is on.
  url_auth  = var.enable_cloudfront || !var.allow_public_access ? "AWS_IAM" : "NONE"
  qualifier = local.use_alias ? aws_lambda_alias.live[0].name : null
}

module "aws_common" {
  source = "./modules/aws-common"

  compute_platform = "lambda"
  service_name     = var.service_name
  tags             = var.tags

  task_role_arn      = var.role_arn
  source_buckets     = var.source_buckets
  cache_bucket       = var.cache_bucket
  enable_monitoring  = var.enable_monitoring
  secret_arns        = local.use_secret ? [aws_secretsmanager_secret.env[0].arn] : []
  log_group_name     = "/aws/lambda/${local.function_name}"
  log_retention_days = var.log_retention_days
  lambda_vpc_access  = local.use_vpc

  create_alb      = false
  alb_target_type = "ip"

  enable_cloudfront               = var.enable_cloudfront
  lambda_function_url             = aws_lambda_function_url.main.function_url
  cloudfront_certificate_arn      = var.cloudfront_certificate_arn
  cloudfront_domains              = var.cloudfront_domains
  cloudfront_origin_shield_region = var.cloudfront_origin_shield_region
  cdn_default_ttl                 = var.cdn_default_ttl
  cdn_min_ttl                     = var.cdn_min_ttl
  cdn_max_ttl                     = var.cdn_max_ttl
  cdn_redirect_http_to_https      = var.cdn_redirect_http_to_https
  cdn_waf_web_acl_id              = var.cdn_waf_web_acl_id
  cdn_cache_headers               = module.imgproxy_common.cdn_cache_headers
  cdn_cache_cookies               = module.imgproxy_common.cdn_cache_cookies
}

# ── Container image (ECR) ─────────────────────────────────────────────────────
# Lambda runs images from ECR only, so the upstream image is copied into a
# repository of its own (skipped when image_uri is set, or when repo is already an ECR
# repository in this account and region).

resource "aws_ecr_repository" "main" {
  count                = local.mirror ? 1 : 0
  name                 = var.service_name
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "main" {
  count      = local.mirror ? 1 : 0
  repository = aws_ecr_repository.main[0].name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 5 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_ecr_repository_policy" "main" {
  count      = local.mirror ? 1 : 0
  repository = aws_ecr_repository.main[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "LambdaPull"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
      Condition = {
        StringLike = {
          "aws:sourceArn" = "arn:aws:lambda:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:function:*"
        }
      }
    }]
  })
}

# Needs crane, the AWS CLI (and jq with repo_credentials_secret) where Terraform runs.
resource "terraform_data" "mirror" {
  count = local.mirror ? 1 : 0

  triggers_replace = [
    module.imgproxy_common.image,
    local.platform,
    aws_ecr_repository.main[0].repository_url,
  ]

  provisioner "local-exec" {
    command = "${path.module}/scripts/mirror-image.sh \"$SRC\" \"$DST\" \"$REGION\" \"$PLATFORM\" \"$CREDENTIALS\""

    environment = {
      SRC         = module.imgproxy_common.image
      DST         = "${aws_ecr_repository.main[0].repository_url}:${local.mirror_tag}"
      REGION      = data.aws_region.current.region
      PLATFORM    = local.platform
      CREDENTIALS = var.repo_credentials_secret != null ? var.repo_credentials_secret.arn : ""
    }
  }
}

data "aws_ecr_image" "main" {
  count           = local.mirror ? 1 : 0
  repository_name = aws_ecr_repository.main[0].name
  image_tag       = local.mirror_tag

  depends_on = [terraform_data.mirror]
}

locals {
  image_uri = (
    local.mirror ? "${aws_ecr_repository.main[0].repository_url}@${data.aws_ecr_image.main[0].image_digest}" :
    var.image_uri != null ? var.image_uri :
    "${var.repo}${startswith(var.tag, "sha256:") ? "@" : ":"}${var.tag}"
  )
}

# ── Secrets ───────────────────────────────────────────────────────────────────
# Lambda cannot inject Secrets Manager values like ECS does, so the secrets are
# gathered into one dotenv secret that imgproxy loads itself on start
# (IMGPROXY_ENV_AWS_SECRET_ID). The values pass through Terraform state.

data "aws_secretsmanager_secret_version" "env" {
  for_each   = local.env_secret_vars
  secret_id  = each.value["arn"]
  version_id = each.value["version"] != "" ? each.value["version"] : null
}

resource "aws_secretsmanager_secret" "env" {
  count                   = local.use_secret ? 1 : 0
  name_prefix             = "${var.service_name}-env-"
  description             = "${var.service_name} imgproxy secrets, loaded by imgproxy at start-up."
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "env" {
  count     = local.use_secret ? 1 : 0
  secret_id = aws_secretsmanager_secret.env[0].id

  secret_string = join("\n", [
    for k in sort(keys(local.env_secret_vars)) : "${k}='${data.aws_secretsmanager_secret_version.env[k].secret_string}'"
  ])
}

# ── Lambda function ───────────────────────────────────────────────────────────

resource "aws_security_group" "function" {
  count       = local.use_vpc ? 1 : 0
  name_prefix = "${var.service_name}-function-"
  vpc_id      = var.vpc_id
  description = "${var.service_name} Lambda function"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.service_name}-function" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lambda_function" "main" {
  function_name = local.function_name
  role          = module.aws_common.task_role_arn
  package_type  = "Image"
  image_uri     = local.image_uri
  architectures = [var.architecture]
  memory_size   = var.memory_size
  timeout       = var.function_timeout
  publish       = local.use_alias

  reserved_concurrent_executions = var.reserved_concurrency

  ephemeral_storage {
    size = var.ephemeral_storage_size
  }

  environment {
    variables = merge(
      local.env_vars,
      local.cloudwatch_env_vars,
      local.use_secret ? {
        IMGPROXY_ENV_AWS_SECRET_ID         = aws_secretsmanager_secret.env[0].arn
        IMGPROXY_ENV_AWS_SECRET_VERSION_ID = aws_secretsmanager_secret_version.env[0].version_id
        IMGPROXY_ENV_AWS_SECRET_REGION     = data.aws_region.current.region
      } : {},
    )
  }

  tracing_config {
    mode = var.enable_monitoring ? "Active" : "PassThrough"
  }

  logging_config {
    log_format = "Text"
    log_group  = module.aws_common.log_group_name
  }

  dynamic "vpc_config" {
    for_each = local.use_vpc ? [1] : []
    content {
      subnet_ids         = var.subnet_ids
      security_group_ids = concat(aws_security_group.function[*].id, var.additional_security_group_ids)
    }
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = var.image_uri != null || !var.pro || var.repo != null || var.repo_credentials_secret != null
      error_message = "repo_credentials_secret is required when pro = true and repo is not set."
    }
    precondition {
      condition     = var.insecure || (var.keys_secret != null && var.salts_secret != null)
      error_message = "keys_secret and salts_secret are required when insecure = false."
    }
    precondition {
      condition     = !var.enable_cloudfront || var.secret_secret == null
      error_message = "secret_secret cannot be used with enable_cloudfront = true. CloudFront does not forward the Authorization header."
    }
    precondition {
      condition     = length(var.cloudfront_domains) == 0 || var.cloudfront_certificate_arn != null
      error_message = "cloudfront_certificate_arn is required when cloudfront_domains is set."
    }
    precondition {
      condition     = var.vpc_id == null || length(var.subnet_ids) > 0
      error_message = "subnet_ids is required when vpc_id is set."
    }
    precondition {
      condition     = var.timeout == null ? true : var.timeout < var.function_timeout
      error_message = "timeout must be less than function_timeout."
    }
    precondition {
      condition     = var.reserved_concurrency == null ? true : var.reserved_concurrency >= var.provisioned_concurrency
      error_message = "reserved_concurrency must not be less than provisioned_concurrency."
    }
    precondition {
      condition     = alltrue([for v in data.aws_secretsmanager_secret_version.env : !strcontains(v.secret_string, "'") && !strcontains(v.secret_string, "\n")])
      error_message = "Secret values must not contain single quotes or newlines: they are written to a dotenv secret."
    }
    precondition {
      condition     = var.image_uri == null ? true : startswith(var.image_uri, "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.region}.amazonaws.com/")
      error_message = "image_uri must be an ECR image in this account and region (<account>.dkr.ecr.<region>.amazonaws.com/...): Lambda cannot run images from other registries, accounts or regions."
    }
  }
}

# Provisioned concurrency applies to a published version, addressed through an alias.
resource "aws_lambda_alias" "live" {
  count            = local.use_alias ? 1 : 0
  name             = "live"
  function_name    = aws_lambda_function.main.function_name
  function_version = aws_lambda_function.main.version
}

resource "aws_lambda_provisioned_concurrency_config" "main" {
  count                             = local.use_alias ? 1 : 0
  function_name                     = aws_lambda_function.main.function_name
  qualifier                         = aws_lambda_alias.live[0].name
  provisioned_concurrent_executions = var.provisioned_concurrency
}

# ── Function URL ──────────────────────────────────────────────────────────────

# imgproxy streams responses (the image sets AWS_LWA_INVOKE_MODE=response_stream).
resource "aws_lambda_function_url" "main" {
  function_name      = aws_lambda_function.main.function_name
  qualifier          = local.qualifier
  authorization_type = local.url_auth
  invoke_mode        = "RESPONSE_STREAM"
}

resource "aws_lambda_permission" "public_url" {
  count                  = local.url_auth == "NONE" ? 1 : 0
  statement_id           = "FunctionURLAllowPublicAccess"
  function_name          = aws_lambda_function.main.function_name
  qualifier              = local.qualifier
  action                 = "lambda:InvokeFunctionUrl"
  principal              = "*"
  function_url_auth_type = "NONE"
}

# Since October 2025 a Function URL needs lambda:InvokeFunction as well, limited to URL calls.
resource "aws_lambda_permission" "public_url_invoke" {
  count                    = local.url_auth == "NONE" ? 1 : 0
  statement_id             = "FunctionURLAllowPublicInvoke"
  function_name            = aws_lambda_function.main.function_name
  qualifier                = local.qualifier
  action                   = "lambda:InvokeFunction"
  principal                = "*"
  invoked_via_function_url = true
}

resource "aws_lambda_permission" "cloudfront_url" {
  count                  = var.enable_cloudfront ? 1 : 0
  statement_id           = "AllowCloudFrontInvokeFunctionUrl"
  function_name          = aws_lambda_function.main.function_name
  qualifier              = local.qualifier
  action                 = "lambda:InvokeFunctionUrl"
  principal              = "cloudfront.amazonaws.com"
  source_arn             = module.aws_common.cloudfront_distribution_arn
  function_url_auth_type = "AWS_IAM"
}

resource "aws_lambda_permission" "cloudfront_url_invoke" {
  count                    = var.enable_cloudfront ? 1 : 0
  statement_id             = "AllowCloudFrontInvokeFunction"
  function_name            = aws_lambda_function.main.function_name
  qualifier                = local.qualifier
  action                   = "lambda:InvokeFunction"
  principal                = "cloudfront.amazonaws.com"
  source_arn               = module.aws_common.cloudfront_distribution_arn
  invoked_via_function_url = true
}
