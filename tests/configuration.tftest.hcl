mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }

  mock_data "aws_ecr_image" {
    defaults = { image_digest = "sha256:00000000000000000000000000000000000000000000000000000000000000aa" }
  }
}

variables {
  image_uri = "123456789012.dkr.ecr.us-east-1.amazonaws.com/imgproxy:v4"
  keys_secret = {
    arn     = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy/keys"
    version = ""
  }
  salts_secret = {
    arn     = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy/salts"
    version = ""
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
    condition     = length(aws_lambda_permission.public_url_invoke) == 0 && length(aws_lambda_permission.cloudfront_url) == 1 && length(aws_lambda_permission.cloudfront_url_invoke) == 1
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
    condition     = length(aws_lambda_permission.public_url_invoke) == 0
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

run "image_uri_is_used_as_given" {
  command = plan

  variables {
    image_uri = "123456789012.dkr.ecr.us-east-1.amazonaws.com/imgproxy@sha256:0123456789abcdef"
  }

  assert {
    condition     = aws_lambda_function.main.image_uri == "123456789012.dkr.ecr.us-east-1.amazonaws.com/imgproxy@sha256:0123456789abcdef"
    error_message = "The function must run image_uri"
  }

  assert {
    condition     = length(data.aws_ecr_image.main) == 0
    error_message = "image_uri must not be looked up"
  }
}

run "repo_and_tag_run_by_digest" {
  command = plan

  variables {
    image_uri = null
    repo      = "123456789012.dkr.ecr.us-east-1.amazonaws.com/my-imgproxy"
    tag       = "v3.30"
  }

  assert {
    condition     = data.aws_ecr_image.main[0].registry_id == "123456789012" && data.aws_ecr_image.main[0].repository_name == "my-imgproxy" && data.aws_ecr_image.main[0].image_tag == "v3.30"
    error_message = "The tag must be looked up in the repo's ECR repository"
  }

  assert {
    condition     = aws_lambda_function.main.image_uri == "123456789012.dkr.ecr.us-east-1.amazonaws.com/my-imgproxy@sha256:00000000000000000000000000000000000000000000000000000000000000aa"
    error_message = "The function must run the image by digest"
  }
}

run "digest_tag_is_looked_up_by_digest" {
  command = plan

  variables {
    image_uri = null
    repo      = "123456789012.dkr.ecr.us-east-1.amazonaws.com/my-imgproxy"
    tag       = "sha256:0123456789abcdef"
  }

  assert {
    condition     = data.aws_ecr_image.main[0].image_digest == "sha256:0123456789abcdef"
    error_message = "A sha256 tag must be looked up by digest"
  }
}
