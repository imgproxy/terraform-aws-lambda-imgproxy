# imgproxy Terraform Module for AWS Lambda

Terraform module to deploy [imgproxy](https://imgproxy.net/) on AWS Lambda as a container image behind a Function URL, with optional CloudFront and S3 integration.

## Features

- Lambda function running imgproxy, with a response-streaming Function URL
- Runs an imgproxy image from your own ECR repository (Lambda runs ECR images only; [how to set it up](#image-delivery))
- Provisioned and reserved concurrency (optional)
- VPC attachment (optional)
- IAM function role (or bring your own)
- CloudFront distribution (optional), with the Function URL locked to it
- X-Ray tracing and CloudWatch metrics (optional)

Also supported: request signing, imgproxy Pro (use the Pro image, see [Image delivery](#image-delivery)), S3 as image source and result cache (Pro). Secure by default ([details](#secure-defaults)).

## Usage

```hcl
module "imgproxy" {
  source  = "imgproxy/lambda-imgproxy/aws"
  version = "~> 0.1"

  service_name = "imgproxy"

  repo = "123456789012.dkr.ecr.us-east-1.amazonaws.com/imgproxy" # your ECR repository, see Image delivery
  tag  = "v4"

  keys_secret  = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy-keys-AbCdEf" }
  salts_secret = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy-salts-AbCdEf" }
}
```

Requires Terraform >= 1.5, AWS provider >= 6.28 and a deployer with [sufficient permissions](#permissions).

> [!CAUTION]
> Lambda only runs images from ECR in the function's region, so before applying you
> need an ECR repository that holds the image ([Image delivery](#image-delivery)).
> Docker is needed only to push the image, not by the module.

## Examples

Start with [insecure](examples/insecure/) and follow the "Next" link at the end of each README; every step adds one feature.

- [insecure](examples/insecure/) - Minimal deployment without request signing (development only)
- [signed](examples/signed/) - URL signing, plus the [production setup](examples/signed/#production-setup)
- [s3](examples/s3/) - Private S3 bucket as the image source
- [cdn](examples/cdn/) - CloudFront in front of the Function URL
- [pro](examples/pro/) - imgproxy Pro with license key and S3 result cache
- [complete](examples/complete/) - monitoring, CloudFront and provisioned concurrency together (imgproxy Pro optional)

## Notes

### Secure defaults

Requests must be signed. `insecure = true` is an explicit development opt-in: anyone can use your imgproxy and, with `source_buckets`, read those buckets.

The Function URL is public by default. `allow_public_access = false` makes it IAM-only (SigV4). With `enable_cloudfront = true` it is IAM-only automatically, callable by your distribution alone.

### Permissions

The deployer needs permissions for Lambda, ECR, Secrets Manager, CloudWatch log groups, CloudFront and, with a VPC, EC2 networking. Two example policies are provided. Replace `123456789012` with your account ID. Statements match names starting with `imgproxy`; if your `service_name` differs, change the prefix (the module names its role `<service_name>-function-*` and its dotenv secret `<service_name>-env-*`).

- [example-permission-set.json](example-permission-set.json): the module creates the function role, so the deployer needs IAM access limited to `imgproxy*-function-*` roles. Treat this identity as privileged.
- [example-permission-set-existing-roles.json](example-permission-set-existing-roles.json): you pass your own `role_arn`; the deployer needs only `iam:PassRole` on it. The role needs logging, secrets access and, with a VPC, the VPC access policy.

Notes:

- `ReadSecretValues` allows `secretsmanager:GetSecretValue` on secrets named `imgproxy*`; narrow it to the secrets you pass.
- Drop the EC2 statements if you use no VPC.
- `EcrLogin` and `EcrRepository` cover creating the repository and pushing the image. The module itself only needs `ecr:DescribeImages`, `ecr:BatchGetImage` and `ecr:GetDownloadUrlForLayer`.
- With `cdn_waf_web_acl_id`, add the WAF read permissions your account requires.

The policies were not applied to a real AWS account; adjust them if an apply fails with `AccessDenied`.

### Networking

By default the function runs outside any VPC, with internet access. Set `vpc_id` and `subnet_ids` (private subnets) only to reach private resources; the function then needs a **NAT gateway** for internet source images, or VPC endpoints for S3 and Secrets Manager. Add rules via `security_group_id` or `additional_security_group_ids`.

### Additional secrets

`secrets` maps extra environment variables (named as in [imgproxy's configuration](https://docs.imgproxy.net/configuration)) to Secrets Manager secrets. Lambda can't inject secrets like ECS, so the module copies all secret values (signing keys, license key, `secrets`) into one dotenv secret that imgproxy loads at start (`IMGPROXY_ENV_AWS_SECRET_ID`). The values pass through the Terraform state, so protect it. Values must not contain single quotes or newlines.

```hcl
secrets = {
  IMGPROXY_SENTRY_DSN = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sentry-dsn-AbCdEf" }
}
```

### Image delivery

Lambda runs only ECR images, from the function's own region. The module does not create the repository or copy the image: you do both, so nothing happens implicitly during `apply`. The module then runs the image you point it at, by digest.

**1. Define the repository** in your own configuration:

```hcl
resource "aws_ecr_repository" "imgproxy" {
  name = "imgproxy"
}
```

Provision it before anything else: the repository must exist (`terraform apply -target=aws_ecr_repository.imgproxy`, or a separate configuration) before you push the image or create the function.

**2. Push the image** to it. imgproxy publishes single-platform images with an architecture suffix, so pull the one for the function's architecture (`-arm64` by default, `-amd64` with `architecture = "x86_64"`), tag it for your repository and push it. The official image `ghcr.io/imgproxy/imgproxy` bundles the Lambda Web Adapter:

```bash
REGISTRY=123456789012.dkr.ecr.us-east-1.amazonaws.com
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $REGISTRY
docker pull ghcr.io/imgproxy/imgproxy:v4-arm64
docker tag ghcr.io/imgproxy/imgproxy:v4-arm64 $REGISTRY/imgproxy:v4
docker push $REGISTRY/imgproxy:v4
```

**imgproxy Pro:** use the Pro image instead. Log in to its registry first (the username is `imgproxy`, the password is your Pro registry credential), then pull, tag and push the same way, and pass the license key with `pro_license_key_secret` ([pro example](examples/pro/)):

```bash
REGISTRY=123456789012.dkr.ecr.us-east-1.amazonaws.com
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $REGISTRY
docker login docker.imgproxy.pro --username imgproxy
docker pull docker.imgproxy.pro/imgproxy:v4-arm64
docker tag docker.imgproxy.pro/imgproxy:v4-arm64 $REGISTRY/imgproxy:v4
docker push $REGISTRY/imgproxy:v4
```

Pro-only inputs (`pro_license_key_secret`, `cache_bucket`, `trusted_signatures_secret`) need the Pro image; the free image ignores or rejects them.

Lambda rejects multi-platform indexes, so push a single-platform image: check with `docker buildx imagetools inspect <image>` if you built the image yourself.

**3. Point the module at it:**

```hcl
module "imgproxy" {
  # ...
  repo = aws_ecr_repository.imgproxy.repository_url
  tag  = "v4" # a version or a sha256: digest

  # Or set image_uri (full URI, used as is; repo and tag are then ignored), e.g.
  # for a repository in another account. In this case, you also need to apply permissions.
}
```

### Scaling, monitoring and logs

- Lambda scales by itself and gives each instance one request; imgproxy detects Lambda and always runs with one worker (`IMGPROXY_WORKERS` is ignored). `memory_size` sets CPU (about 1 vCPU per 1769 MB).
- `reserved_concurrency` caps the function. `provisioned_concurrency` keeps instances initialized (billed continuously); the function is then published to the `live` alias and the Function URL points at it.
- `enable_monitoring = true` turns on X-Ray tracing and imgproxy's CloudWatch metrics (namespace `imgproxy`).
- `source_buckets` and `cache_bucket` (Pro) grant IAM access to existing buckets; the module doesn't create them. Set `IMGPROXY_S3_REGION` in `environment` for buckets outside the default region.
- imgproxy Pro sends its license heartbeat via a Lambda extension, with no setup. Each instance activates the license under the function name, so keep `reserved_concurrency` within your license's limit.
- Responses are streamed, lifting the 6 MB buffered limit. `function_timeout` must exceed `timeout`.
- The function is named `service_name` unless you set `function_name`. Logs go to `/aws/lambda/<function name>`, kept `log_retention_days` (365 by default).

### CloudFront

`enable_cloudfront = true` puts CloudFront in front of the Function URL, on its `*.cloudfront.net` domain or yours via `cloudfront_domains` and `cloudfront_certificate_arn` (issued in **us-east-1**).

The Function URL requires IAM and only your distribution may call it (Origin Access Control, SigV4), so there is no origin secret or extra certificate to manage.

**Source URLs:** a double slash (`//`) in the path breaks the SigV4 request to the Function URL (`403 The request signature we calculated does not match`). Sources like `plain/s3://bucket/key` or `plain/https://host/image.jpg` contain one, so percent-encode them (`plain/s3%3A%2F%2Fbucket%2Fkey`) or base64-encode the source. Colons and `@` are fine.

Cache keys follow your imgproxy configuration (`Accept` with format detection, client hints, `IMGPROXY_CACHE_KEY_HEADERS`, `IMGPROXY_CACHE_KEY_COOKIES`). CloudFront doesn't forward `Authorization`, so `secret_secret` can't be used with it. Query strings aren't forwarded either: percent-encode any `?` in plain source URLs.

### Vendored modules

`modules/aws-common` and `modules/imgproxy-common` are generated copies from `imgproxy/terraform-common`. Don't edit them here; change them upstream and run its `sync.sh`.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.5 |
| aws | >= 6.28 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | >= 6.28 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| aws\_common | ./modules/aws-common | n/a |
| imgproxy\_common | ./modules/imgproxy-common | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_lambda_alias.live](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_alias) | resource |
| [aws_lambda_function.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_function_url.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function_url) | resource |
| [aws_lambda_permission.cloudfront_url](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_lambda_permission.cloudfront_url_invoke](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_lambda_permission.public_url_invoke](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_lambda_provisioned_concurrency_config.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_provisioned_concurrency_config) | resource |
| [aws_secretsmanager_secret.env](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_version.env](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_security_group.function](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_ecr_image.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ecr_image) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_secretsmanager_secret_version.env](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/secretsmanager_secret_version) | data source |

## Inputs

| Name | Description | Type | Required |
| ---- | ----------- | ---- | :------: |
| additional\_security\_group\_ids | Additional security group IDs to attach to the function. | `list(string)` | no |
| allow\_public\_access | Make the Function URL publicly callable (authorization NONE). When false, callers must sign requests with SigV4 (authorization AWS\_IAM). Ignored when enable\_cloudfront = true: CloudFront is then the only caller. | `bool` | no |
| architecture | Instruction set architecture of the function. arm64 (Graviton) is recommended: lower cost, same performance. The image you copy into ECR must be built for this architecture. | `string` | no |
| cache\_bucket | S3 bucket name for imgproxy result cache (imgproxy Pro only). The function role is granted full object access. | `string` | no |
| cdn\_default\_ttl | Default CloudFront TTL in seconds. Set to 0 to let CloudFront respect origin Cache-Control headers. | `number` | no |
| cdn\_max\_ttl | Maximum CloudFront TTL in seconds, regardless of origin headers. | `number` | no |
| cdn\_min\_ttl | Minimum CloudFront TTL in seconds. Set to a positive value to force a floor TTL regardless of origin headers. | `number` | no |
| cdn\_redirect\_http\_to\_https | Redirect HTTP to HTTPS at the CloudFront level. | `bool` | no |
| cdn\_waf\_web\_acl\_id | WAF Web ACL ARN to associate with the CloudFront distribution. | `string` | no |
| cloudfront\_certificate\_arn | ACM certificate ARN for CloudFront (must be in us-east-1). Required when cloudfront\_domains is set. | `string` | no |
| cloudfront\_domains | Custom domain aliases for the CloudFront distribution. Requires cloudfront\_certificate\_arn. | `list(string)` | no |
| cloudfront\_origin\_shield\_region | AWS region to enable CloudFront Origin Shield (e.g. "us-east-1"). Adds an extra caching tier between edge locations and the function, reducing invocations. When null, Origin Shield is disabled. | `string` | no |
| enable\_cloudfront | Create a CloudFront distribution in front of the Function URL for global edge caching. The Function URL then accepts only requests signed by this distribution (Origin Access Control). | `bool` | no |
| enable\_monitoring | Enable X-Ray active tracing and imgproxy's CloudWatch metrics (namespace 'imgproxy'), and grant the function role the matching permissions. | `bool` | no |
| environment | Additional environment variables passed to imgproxy (e.g. IMGPROXY\_MAX\_SRC\_RESOLUTION). | `map(string)` | no |
| ephemeral\_storage\_size | Size of the function's /tmp in MB (512–10240). | `number` | no |
| function\_name | Lambda function name. Defaults to service\_name. The log group is /aws/lambda/<function\_name>. With imgproxy Pro the name is also reported to the license server as the host name of the activation. | `string` | no |
| function\_timeout | Lambda function timeout in seconds (1–900). | `number` | no |
| image\_uri | Full URI of the image in ECR, in the function's region (<account>.dkr.ecr.<region>.amazonaws.com/<name>:<tag> or @sha256:<digest>). Used as it is; repo and tag are ignored. Use it to pin an exact digest or when the repository is in another account. | `string` | no |
| insecure | Disable URL signature checks. When true, key and salt are not required. | `bool` | no |
| keys\_secret | Secrets Manager ARN for imgproxy signing keys (comma-separated hex-encoded values). Required when insecure = false. Generate: openssl rand -hex 64. Sets IMGPROXY\_KEY. | ```object({ arn = string version = optional(string, "") })``` | no |
| log\_retention\_days | CloudWatch log group retention in days. | `number` | no |
| memory\_size | Memory in MB (128–10240). Lambda allocates CPU in proportion: about 1 vCPU per 1769 MB. | `number` | no |
| pro\_license\_key\_secret | Secrets Manager ARN for the imgproxy Pro license key. Sets IMGPROXY\_LICENSE\_KEY. | ```object({ arn = string version = optional(string, "") })``` | no |
| provisioned\_concurrency | Number of pre-initialized instances kept warm, which removes cold starts for that many concurrent requests. When above 0, the function is published to a 'live' alias and the Function URL points at the alias. Billed continuously. | `number` | no |
| repo | ECR repository that holds the imgproxy image, without tag: <account>.dkr.ecr.<region>.amazonaws.com/<name>. Lambda runs only ECR images from the function's region, and this module neither creates the repository nor copies the image: do both yourself (see the README). The image must be single-platform for the function's architecture, and the repository must allow lambda.amazonaws.com to pull it. Set this (with 'tag') or image\_uri. | `string` | no |
| reserved\_concurrency | Maximum concurrent executions of the function (reserved concurrency). When null, the function draws on the account's unreserved pool. Set it to cap cost and protect the account limit. | `number` | no |
| role\_arn | ARN of an existing IAM role to use as the function role. When null, a role is created with logging, S3, Secrets Manager and monitoring permissions as needed. A custom role needs those permissions itself (and the VPC access policy when vpc\_id is set). | `string` | no |
| salts\_secret | Secrets Manager ARN for imgproxy signing salts (must match number of keys). Required when insecure = false. Sets IMGPROXY\_SALT. | ```object({ arn = string version = optional(string, "") })``` | no |
| secret\_secret | Secrets Manager ARN for the authorization token. When set, requests must include Authorization: Bearer <token>. Sets IMGPROXY\_SECRET. | ```object({ arn = string version = optional(string, "") })``` | no |
| secrets | Map of environment variable names to Secrets Manager ARNs. Example: {IMGPROXY\_NEW\_RELIC\_KEY = {arn = "arn:aws:secretsmanager:us-east-1:123:secret:newrelic-key"}}. Values must not contain single quotes or newlines. | ```map(object({ arn = string version = optional(string, "") }))``` | no |
| service\_name | Prefix applied to every resource name. Also the Lambda function name unless function\_name is set. | `string` | no |
| signature\_size | Number of bytes from the key/salt used for signing. Sets IMGPROXY\_SIGNATURE\_SIZE. | `number` | no |
| source\_buckets | S3 bucket names for imgproxy source images. The function role is granted s3:GetObject, s3:GetObjectVersion and s3:ListBucket on each. Enables IMGPROXY\_USE\_S3. | `list(string)` | no |
| source\_url\_encryption\_key\_secret | Secrets Manager ARN for the source URL encryption key. Sets IMGPROXY\_SOURCE\_URL\_ENCRYPTION\_KEY. | ```object({ arn = string version = optional(string, "") })``` | no |
| subnet\_ids | Subnet IDs for the function ENIs. Required when vpc\_id is set; use private subnets. | `list(string)` | no |
| tag | imgproxy image tag (version) in the ECR repository given by 'repo'. Pin a version or a sha256: digest. The function runs the image by digest, so pushing a new image under the same tag and applying again redeploys it. Ignored when image\_uri is set. | `string` | no |
| tags | Tags applied to all created resources. | `map(string)` | no |
| timeout | imgproxy request timeout in seconds. Sets IMGPROXY\_TIMEOUT. Keep it below function\_timeout. | `number` | no |
| trusted\_signatures\_secret | Secrets Manager ARN for trusted signature prefixes. imgproxy Pro only. Sets IMGPROXY\_TRUSTED\_SIGNATURES. | ```object({ arn = string version = optional(string, "") })``` | no |
| vpc\_id | VPC ID to attach the function to. Only needed to reach private resources: the function then loses internet access unless the subnets route through a NAT gateway or VPC endpoints for S3 and Secrets Manager. When null, the function runs outside any VPC. | `string` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| cloudfront\_domain\_name | CloudFront distribution domain name. |
| cloudfront\_hosted\_zone\_id | CloudFront hosted zone ID. Use with Route 53 alias records. |
| function\_arn | Lambda function ARN. |
| function\_name | Lambda function name. |
| function\_url | Lambda Function URL (the origin behind CloudFront when enabled). |
| image\_uri | ECR image the function runs. |
| log\_group\_name | CloudWatch Log Group name for imgproxy logs. |
| role\_arn | ARN of the IAM role used by the function at runtime. |
| security\_group\_id | Security group ID attached to the function (null when not attached to a VPC). |
| url | imgproxy endpoint URL. CloudFront domain when enable\_cloudfront = true, otherwise the Function URL. |
<!-- END_TF_DOCS -->

## License

MIT
