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

run "default_service_name" {
  command = plan

  assert {
    condition     = aws_lambda_function.main.function_name == "imgproxy"
    error_message = "Function name must equal service_name default"
  }

  assert {
    condition     = module.aws_common.log_group_name == "/aws/lambda/imgproxy"
    error_message = "Log group name must follow the Lambda naming convention"
  }
}

run "custom_service_name_propagates" {
  command = plan

  variables {
    service_name = "myapp"
  }

  assert {
    condition     = aws_lambda_function.main.function_name == "myapp"
    error_message = "Function name must reflect service_name"
  }

  assert {
    condition     = module.aws_common.log_group_name == "/aws/lambda/myapp"
    error_message = "Log group name must use service_name"
  }
}

run "container_image_package" {
  command = plan

  assert {
    condition     = aws_lambda_function.main.package_type == "Image"
    error_message = "Function must run a container image"
  }

  assert {
    condition     = aws_lambda_function.main.architectures == tolist(["arm64"])
    error_message = "Default architecture must be arm64"
  }
}

run "default_sizing" {
  command = plan

  assert {
    condition     = aws_lambda_function.main.memory_size == 2048
    error_message = "Default memory must be 2048 MB"
  }

  assert {
    condition     = aws_lambda_function.main.timeout == 30
    error_message = "Default function timeout must be 30 seconds"
  }

  assert {
    condition     = aws_lambda_function.main.environment[0].variables["IMGPROXY_WORKERS"] == "1"
    error_message = "Lambda serves one request per instance, so workers must default to 1"
  }
}

run "image_uri_is_the_function_image" {
  command = plan

  assert {
    condition     = aws_lambda_function.main.image_uri == "123456789012.dkr.ecr.us-east-1.amazonaws.com/imgproxy:v4"
    error_message = "The function must run image_uri as given"
  }
}

run "function_url_is_public_by_default" {
  command = plan

  assert {
    condition     = aws_lambda_function_url.main.authorization_type == "NONE"
    error_message = "Function URL must be public without CloudFront by default"
  }

  assert {
    condition     = aws_lambda_function_url.main.invoke_mode == "RESPONSE_STREAM"
    error_message = "Function URL must stream responses"
  }

  assert {
    condition     = length(aws_lambda_permission.public_url) == 1 && length(aws_lambda_permission.public_url_invoke) == 1
    error_message = "A public Function URL needs both InvokeFunctionUrl and InvokeFunction permissions"
  }
}

run "no_extras_by_default" {
  command = plan

  assert {
    condition     = length(aws_lambda_alias.live) == 0 && length(aws_lambda_provisioned_concurrency_config.main) == 0
    error_message = "No alias or provisioned concurrency by default"
  }

  assert {
    condition     = length(aws_security_group.function) == 0
    error_message = "No VPC attachment by default"
  }

  assert {
    condition     = length(aws_secretsmanager_secret.env) == 1
    error_message = "Signing keys must be delivered through the dotenv secret"
  }

  assert {
    condition     = module.aws_common.cloudfront_created == false
    error_message = "No CloudFront distribution by default"
  }
}

run "tracing_off_by_default" {
  command = plan

  assert {
    condition     = aws_lambda_function.main.tracing_config[0].mode == "PassThrough"
    error_message = "X-Ray tracing must be off by default"
  }
}

run "custom_function_name" {
  command = plan

  variables {
    service_name  = "myapp"
    function_name = "myapp-images"
  }

  assert {
    condition     = aws_lambda_function.main.function_name == "myapp-images"
    error_message = "Function name must use function_name"
  }

  assert {
    condition     = module.aws_common.log_group_name == "/aws/lambda/myapp-images"
    error_message = "Log group must follow function_name"
  }
}
