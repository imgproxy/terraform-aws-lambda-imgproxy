mock_provider "aws" {}

variables {
  keys_secret = {
    arn     = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy/keys"
    version = ""
  }
  salts_secret = {
    arn     = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy/salts"
    version = ""
  }
}

run "pro_image_with_credentials" {
  command = plan

  variables {
    pro = true
    repo_credentials_secret = {
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy/registry"
    }
  }

  assert {
    condition     = terraform_data.mirror[0].triggers_replace[0] == "docker.imgproxy.pro/imgproxy:v4"
    error_message = "pro = true must mirror the Pro image"
  }
}

run "custom_repo_and_tag" {
  command = plan

  variables {
    repo = "registry.example.com/imgproxy"
    tag  = "v3.30"
  }

  assert {
    condition     = terraform_data.mirror[0].triggers_replace[0] == "registry.example.com/imgproxy:v3.30"
    error_message = "repo and tag must form the mirror source"
  }
}

run "digest_tag_is_valid_ecr_tag" {
  command = plan

  variables {
    tag = "sha256:0123456789abcdef"
  }

  assert {
    condition     = terraform_data.mirror[0].triggers_replace[0] == "ghcr.io/imgproxy/imgproxy@sha256:0123456789abcdef"
    error_message = "A sha256 tag must be referenced by digest"
  }

  assert {
    condition     = data.aws_ecr_image.main[0].image_tag == "sha256-0123456789abcdef"
    error_message = "ECR tags cannot contain a colon"
  }
}

run "image_uri_skips_mirroring" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "123456789012" }
  }

  override_data {
    target = data.aws_region.current
    values = { region = "us-east-1" }
  }

  variables {
    image_uri = "123456789012.dkr.ecr.us-east-1.amazonaws.com/imgproxy@sha256:0123456789abcdef"
  }

  assert {
    condition     = length(aws_ecr_repository.main) == 0 && length(terraform_data.mirror) == 0
    error_message = "image_uri must skip the ECR repository and mirroring"
  }

  assert {
    condition     = aws_lambda_function.main.image_uri == "123456789012.dkr.ecr.us-east-1.amazonaws.com/imgproxy@sha256:0123456789abcdef"
    error_message = "The function must run image_uri"
  }
}

run "x86_64_mirrors_amd64" {
  command = plan

  variables {
    architecture = "x86_64"
  }

  assert {
    condition     = terraform_data.mirror[0].triggers_replace[1] == "linux/amd64"
    error_message = "x86_64 must mirror the linux/amd64 image"
  }
}

run "insecure_needs_no_secret" {
  command = plan

  variables {
    insecure     = true
    keys_secret  = null
    salts_secret = null
  }

  assert {
    condition     = length(aws_secretsmanager_secret.env) == 0
    error_message = "No dotenv secret without secrets"
  }

  assert {
    condition     = !contains(keys(aws_lambda_function.main.environment[0].variables), "IMGPROXY_ENV_AWS_SECRET_ID")
    error_message = "No secret loading without secrets"
  }
}

run "extra_secrets_join_the_dotenv_secret" {
  command = plan

  variables {
    secrets = {
      IMGPROXY_NEW_RELIC_KEY = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:newrelic" }
    }
  }

  assert {
    condition     = contains(keys(data.aws_secretsmanager_secret_version.env), "IMGPROXY_NEW_RELIC_KEY")
    error_message = "Extra secrets must be read into the dotenv secret"
  }
}

run "s3_source_enables_s3" {
  command = plan

  variables {
    source_buckets = ["my-images"]
  }

  assert {
    condition     = aws_lambda_function.main.environment[0].variables["IMGPROXY_USE_S3"] == "true"
    error_message = "source_buckets must enable IMGPROXY_USE_S3"
  }
}

run "provisioned_concurrency_uses_alias" {
  command = plan

  variables {
    provisioned_concurrency = 3
  }

  assert {
    condition     = aws_lambda_function.main.publish == true
    error_message = "Provisioned concurrency needs a published version"
  }

  assert {
    condition     = aws_lambda_provisioned_concurrency_config.main[0].provisioned_concurrent_executions == 3
    error_message = "Provisioned concurrency must be configured on the alias"
  }

  assert {
    condition     = aws_lambda_function_url.main.qualifier == "live"
    error_message = "The Function URL must point at the alias"
  }
}

run "vpc_attachment" {
  command = plan

  variables {
    vpc_id     = "vpc-12345678"
    subnet_ids = ["subnet-aaa111", "subnet-bbb222"]
  }

  assert {
    condition     = length(aws_security_group.function) == 1
    error_message = "A security group must be created for the VPC attachment"
  }

  assert {
    condition     = length(aws_lambda_function.main.vpc_config) == 1
    error_message = "The function must be attached to the VPC"
  }
}

run "monitoring_enables_tracing" {
  command = plan

  variables {
    enable_monitoring = true
  }

  assert {
    condition     = aws_lambda_function.main.tracing_config[0].mode == "Active"
    error_message = "enable_monitoring must turn on X-Ray tracing"
  }

  assert {
    condition     = aws_lambda_function.main.environment[0].variables["IMGPROXY_CLOUD_WATCH_NAMESPACE"] == "imgproxy"
    error_message = "enable_monitoring must turn on CloudWatch metrics"
  }
}

run "cloudfront_signs_requests" {
  command = plan

  variables {
    enable_cloudfront = true
  }

  assert {
    condition     = aws_lambda_function_url.main.authorization_type == "AWS_IAM"
    error_message = "With CloudFront the Function URL must require IAM"
  }

  assert {
    condition     = length(aws_lambda_permission.public_url) == 0 && length(aws_lambda_permission.cloudfront_url) == 1 && length(aws_lambda_permission.cloudfront_url_invoke) == 1
    error_message = "Only CloudFront may invoke the Function URL"
  }

  assert {
    condition     = module.aws_common.cloudfront_created == true
    error_message = "A CloudFront distribution must be created"
  }
}

run "private_function_url" {
  command = plan

  variables {
    allow_public_access = false
  }

  assert {
    condition     = aws_lambda_function_url.main.authorization_type == "AWS_IAM"
    error_message = "allow_public_access = false must require IAM"
  }

  assert {
    condition     = length(aws_lambda_permission.public_url) == 0
    error_message = "No public permission for a private Function URL"
  }
}

run "existing_role_is_used" {
  command = plan

  variables {
    role_arn = "arn:aws:iam::123456789012:role/existing"
  }

  assert {
    condition     = aws_lambda_function.main.role == "arn:aws:iam::123456789012:role/existing"
    error_message = "role_arn must be used as the function role"
  }
}

run "reserved_concurrency" {
  command = plan

  variables {
    reserved_concurrency = 20
  }

  assert {
    condition     = aws_lambda_function.main.reserved_concurrent_executions == 20
    error_message = "reserved_concurrency must be applied"
  }
}

run "ecr_repo_in_account_skips_mirroring" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "123456789012" }
  }

  override_data {
    target = data.aws_region.current
    values = { region = "us-east-1" }
  }

  variables {
    repo = "123456789012.dkr.ecr.us-east-1.amazonaws.com/my-imgproxy"
    tag  = "v4"
  }

  assert {
    condition     = length(aws_ecr_repository.main) == 0 && length(terraform_data.mirror) == 0
    error_message = "A repo that is already in this account's ECR must not be mirrored"
  }

  assert {
    condition     = aws_lambda_function.main.image_uri == "123456789012.dkr.ecr.us-east-1.amazonaws.com/my-imgproxy:v4"
    error_message = "The function must use repo:tag directly"
  }
}

run "ecr_repo_with_digest_uses_digest_reference" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "123456789012" }
  }

  override_data {
    target = data.aws_region.current
    values = { region = "us-east-1" }
  }

  variables {
    repo = "123456789012.dkr.ecr.us-east-1.amazonaws.com/my-imgproxy"
    tag  = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  }

  assert {
    condition     = aws_lambda_function.main.image_uri == "123456789012.dkr.ecr.us-east-1.amazonaws.com/my-imgproxy@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    error_message = "A digest tag must be referenced with @"
  }
}

run "ecr_repo_in_other_region_is_still_mirrored" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "123456789012" }
  }

  override_data {
    target = data.aws_region.current
    values = { region = "us-east-1" }
  }

  variables {
    repo = "123456789012.dkr.ecr.eu-west-1.amazonaws.com/my-imgproxy"
    tag  = "v4"
  }

  assert {
    condition     = length(terraform_data.mirror) == 1
    error_message = "An ECR repo in another region cannot be used by the function and must be mirrored"
  }
}
