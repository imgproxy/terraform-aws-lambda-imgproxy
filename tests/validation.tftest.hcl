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

  variables {
    image_uri = "123456789012.dkr.ecr.eu-west-1.amazonaws.com/imgproxy:v4"
  }

  expect_failures = [aws_lambda_function.main]
}

run "accepts_image_uri_in_other_account" {
  command = plan

  variables {
    image_uri = "999999999999.dkr.ecr.us-east-1.amazonaws.com/imgproxy:v4"
  }

  assert {
    condition     = aws_lambda_function.main.image_uri == "999999999999.dkr.ecr.us-east-1.amazonaws.com/imgproxy:v4"
    error_message = "Only the region of the image is checked"
  }
}

run "rejects_missing_image" {
  command = plan

  variables {
    image_uri = null
  }

  expect_failures = [aws_lambda_function.main]
}

run "rejects_repo_outside_ecr" {
  command = plan

  variables {
    image_uri = null
    repo      = "registry.example.com/imgproxy"
  }

  expect_failures = [aws_lambda_function.main]
}

run "rejects_repo_in_other_region" {
  command = plan

  variables {
    image_uri = null
    repo      = "123456789012.dkr.ecr.eu-west-1.amazonaws.com/imgproxy"
  }

  expect_failures = [aws_lambda_function.main]
}
