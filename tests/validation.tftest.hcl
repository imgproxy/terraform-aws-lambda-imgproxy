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

run "rejects_invalid_architecture" {
  command = plan

  variables {
    architecture = "INVALID"
  }

  expect_failures = [var.architecture]
}

run "rejects_memory_out_of_range" {
  command = plan

  variables {
    memory_size = 64
  }

  expect_failures = [var.memory_size]
}

run "rejects_function_timeout_out_of_range" {
  command = plan

  variables {
    function_timeout = 901
  }

  expect_failures = [var.function_timeout]
}

run "rejects_negative_provisioned_concurrency" {
  command = plan

  variables {
    provisioned_concurrency = -1
  }

  expect_failures = [var.provisioned_concurrency]
}

run "rejects_pro_without_registry_credentials" {
  command = plan

  variables {
    pro = true
  }

  expect_failures = [aws_lambda_function.main]
}

run "accepts_pro_with_custom_repo_without_credentials" {
  command = plan

  variables {
    pro  = true
    repo = "registry.example.com/imgproxy-pro"
  }

  assert {
    condition     = aws_lambda_function.main.function_name == "imgproxy"
    error_message = "pro with a custom repo must not require repo_credentials_secret"
  }
}

run "rejects_secure_mode_without_keys" {
  command = plan

  variables {
    keys_secret = null
  }

  # The common module repeats this check; mock it so only the root precondition is evaluated.
  override_module {
    target = module.imgproxy_common
    outputs = {
      image             = "mock"
      workers           = 1
      env_vars          = {}
      env_secret_vars   = {}
      cdn_cache_headers = []
      cdn_cache_cookies = []
    }
  }

  expect_failures = [aws_lambda_function.main]
}

run "rejects_authorization_token_with_cloudfront" {
  command = plan

  variables {
    enable_cloudfront = true
    secret_secret = {
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy/token"
    }
  }

  expect_failures = [aws_lambda_function.main]
}

run "rejects_cloudfront_domains_without_certificate" {
  command = plan

  variables {
    enable_cloudfront  = true
    cloudfront_domains = ["img.example.com"]
  }

  expect_failures = [aws_lambda_function.main]
}

run "rejects_vpc_without_subnets" {
  command = plan

  variables {
    vpc_id = "vpc-12345678"
  }

  expect_failures = [aws_lambda_function.main]
}

run "rejects_imgproxy_timeout_not_below_function_timeout" {
  command = plan

  variables {
    timeout          = 30
    function_timeout = 30
  }

  expect_failures = [aws_lambda_function.main]
}

run "rejects_reserved_below_provisioned_concurrency" {
  command = plan

  variables {
    reserved_concurrency    = 1
    provisioned_concurrency = 2
  }

  expect_failures = [aws_lambda_function.main]
}

run "rejects_image_uri_outside_ecr" {
  command = plan

  variables {
    image_uri = "ghcr.io/imgproxy/imgproxy:v4"
  }

  expect_failures = [aws_lambda_function.main]
}

run "rejects_image_uri_in_other_region" {
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
    image_uri = "123456789012.dkr.ecr.eu-west-1.amazonaws.com/imgproxy:v4"
  }

  expect_failures = [aws_lambda_function.main]
}

run "rejects_image_uri_in_other_account" {
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
    image_uri = "999999999999.dkr.ecr.us-east-1.amazonaws.com/imgproxy:v4"
  }

  expect_failures = [aws_lambda_function.main]
}
