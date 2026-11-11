# imgproxy Terraform Module for AWS Lambda

Terraform module to deploy [imgproxy](https://imgproxy.net/) on AWS Lambda as a container image behind a Function URL, with optional CloudFront and S3 integration.

## Features

The module creates the required resources:

- Lambda function running the imgproxy container image, with a Function URL that streams responses
- ECR repository with the imgproxy image mirrored into it (Lambda runs ECR images only)
- Provisioned and reserved concurrency (optional)
- VPC attachment (optional)
- IAM function role (or use your own)
- CloudFront distribution (optional), with the Function URL locked to it
- X-Ray tracing and CloudWatch metrics (optional)

Also supported: request signing, imgproxy Pro and private registries through Secrets Manager, S3 as image source and result cache (Pro). Secure by default ([details](#secure-defaults)).

## Usage

```hcl
module "imgproxy" {
  source  = "imgproxy/lambda-imgproxy/aws"
  version = "~> 0.1"

  service_name = "imgproxy"

  keys_secret  = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy-keys-AbCdEf" }
  salts_secret = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy-salts-AbCdEf" }

  enable_cloudfront       = true # the Function URL then accepts only CloudFront
  provisioned_concurrency = 2    # keep two instances warm
}
```

Requires Terraform >= 1.5, AWS provider >= 6.28, an authenticated AWS CLI with [sufficient permissions](#permissions), and [crane](https://github.com/google/go-containerregistry/blob/main/cmd/crane/README.md#installation) (plus `jq` with `repo_credentials_secret`) to mirror the image, unless `repo` is a pre-created ECR repository or `image_uri` is set ([Image delivery](#image-delivery)). The module creates no networking.

## Examples

Start with [insecure](examples/insecure/) and follow the "Next" link at the end of each README; every step adds one feature.

- [insecure](examples/insecure/) - Minimal deployment without request signing (development only)
- [signed](examples/signed/) - URL signing, plus the [production setup](examples/signed/#production-setup)
- [s3](examples/s3/) - Private S3 bucket as the image source
- [cdn](examples/cdn/) - CloudFront in front of the Function URL
- [pro](examples/pro/) - imgproxy Pro with license key and S3 result cache
- [complete](examples/complete/) - Pro, monitoring, CloudFront and provisioned concurrency together

## Notes

### Secure defaults

Requests must be signed; `insecure = true` is the explicit opt-in for development, where anyone can use your imgproxy and, with `source_buckets`, read those buckets.

The Function URL is public by default. `allow_public_access = false` makes it IAM-only (callers sign with SigV4), and with `enable_cloudfront = true` it is IAM-only automatically, callable by your distribution alone.

### Permissions

The deployer needs permissions for Lambda, ECR, Secrets Manager, CloudWatch log groups, CloudFront and, to attach the function to a VPC, EC2 networking. Two example policies are provided; before using either, replace `123456789012` with your AWS account ID. The statements match names that start with `imgproxy` (a `service_name` such as `imgproxy` or `imgproxy-lambda`): if yours starts differently, change the prefix in every statement (the module names its role `<service_name>-function-*`, its ECR repository `<service_name>` and its dotenv secret `<service_name>-env-*`).

- [example-permission-set.json](example-permission-set.json): the module creates the function role, so the deployer needs IAM access, limited to roles named `imgproxy*-function-*`. Treat this identity as privileged.
- [example-permission-set-existing-roles.json](example-permission-set-existing-roles.json): you create the role and pass it as `role_arn`; the deployer then needs only `iam:PassRole` on it. The role needs logging, secrets access and, with a VPC, the VPC access policy itself.

`ReadSecretValues` allows `secretsmanager:GetSecretValue` on secrets whose names start with `imgproxy`: the module reads the values of the secrets you pass (see [Additional secrets](#additional-secrets)). Narrow it to those secrets, and drop the EC2 statements if you do not attach the function to a VPC. With `repo_credentials_secret` the identity also needs `secretsmanager:GetSecretValue` on that secret (covered when its name starts with `imgproxy`). If `repo` is your own ECR repository, the identity needs `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer` and `ecr:GetRepositoryPolicy` on it, which the `imgproxy*` ECR statement does not cover unless the repository name matches. With `cdn_waf_web_acl_id`, add the WAF read permissions your account requires.

These policies were checked against the module's resources but not applied to a real AWS account; adjust them if an apply fails with `AccessDenied`.

### Networking

By default the function runs outside any VPC with internet access. Set `vpc_id` and `subnet_ids` (private subnets) only to reach private resources; the function then needs a **NAT gateway** to fetch source images from the internet, or VPC endpoints for S3 and Secrets Manager. Add rules through `security_group_id` or `additional_security_group_ids`.

### Additional secrets

`secrets` maps extra environment variables (named as in [imgproxy's configuration](https://docs.imgproxy.net/configuration)) to Secrets Manager secrets. Lambda cannot inject secrets like ECS, so the module copies all secret values (signing keys, license key and `secrets`) into one dotenv secret that imgproxy loads at start (`IMGPROXY_ENV_AWS_SECRET_ID`). The values therefore pass through the Terraform state: protect it. Values must not contain single quotes or newlines.

```hcl
secrets = {
  IMGPROXY_SENTRY_DSN = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sentry-dsn-AbCdEf" }
}
```

### Image delivery

Lambda runs only ECR images from its own account and region, so the module copies `ghcr.io/imgproxy/imgproxy`, or `docker.imgproxy.pro/imgproxy` with `pro = true`, into an ECR repository on apply, for the function's architecture only. The official image already bundles the Lambda Web Adapter. For your own image, set `repo` (without tag) and `tag` (a version, or a `sha256:` digest). If `repo` is already an ECR repository of the same account and region (`<account>.dkr.ecr.<region>.amazonaws.com/...`), nothing is copied and no repository is created: the function uses `repo:tag` directly. Such an image must be single-platform for the function's architecture (Lambda rejects multi-platform indexes), and the repository must allow `lambda.amazonaws.com` to pull from it (`ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`); you manage that yourself. For an image in another account or region, use `image_uri` after copying it yourself.

```hcl
repo                    = "registry.example.com/imgproxy-custom"
repo_credentials_secret = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:registry-AbCdEf" }
tag                     = "my-tag"
```

- Public images and **ECR** need no credentials. Other private registries need `repo_credentials_secret`, a JSON secret with `username` and `password` keys (for docker.imgproxy.pro the username is `imgproxy`). It is read by the machine running Terraform, not by the function.
- The copy runs `scripts/mirror-image.sh` (needs [crane](https://github.com/google/go-containerregistry/blob/main/cmd/crane/README.md#installation) and the AWS CLI) when the image reference changes. Pin `tag`: a moved upstream tag is not re-copied. With a pre-created ECR `repo` (or `image_uri`) nothing is mirrored, so crane is not called and need not be installed.
- To mirror outside Terraform, push the image to ECR yourself and set `image_uri`; nothing is copied then.

Functions run on arm64 (Graviton) by default; for images without `linux/arm64`, set `architecture = "x86_64"`.

### Scaling, monitoring and logs

- Lambda scales by itself and hands one request to each instance, so `workers` defaults to 1. `memory_size` sets the CPU (about 1 vCPU per 1769 MB).
- `reserved_concurrency` caps the function. `provisioned_concurrency` keeps that many instances initialized (billed continuously); the function is then published to the `live` alias and the Function URL points at it.
- `enable_monitoring = true` turns on X-Ray active tracing and imgproxy's CloudWatch metrics (namespace `imgproxy`).
- `source_buckets` and `cache_bucket` (Pro) grant IAM permissions on existing buckets; the module does not create them. Set `IMGPROXY_S3_REGION` in `environment` when a bucket is outside the default region.
- imgproxy Pro registers a Lambda extension and sends its license heartbeat on invocations, so no setting is needed to enable it. Each function instance activates the license under the function name, so keep `reserved_concurrency` within your license's concurrency limit.
- Responses are streamed, which lifts the 6 MB limit of buffered Function URLs. `function_timeout` must exceed `timeout`.
- The function is named `service_name` unless you set `function_name`. Logs go to the CloudWatch group `/aws/lambda/<function name>`, kept for `log_retention_days` (365 by default).

### CloudFront

`enable_cloudfront = true` puts CloudFront in front of the Function URL, on its `*.cloudfront.net` domain or on yours through `cloudfront_domains` and `cloudfront_certificate_arn` (issued in **us-east-1**).

The Function URL is locked to CloudFront: it requires IAM, and only your distribution is allowed to call it (Origin Access Control, SigV4), so there is no origin secret and no extra certificate to manage.

**Source URLs:** a double slash (`//`) in the request path makes the SigV4 request from CloudFront to the Function URL fail with `403 The request signature we calculated does not match`. Source URLs written as `plain/s3://bucket/key` or `plain/https://host/image.jpg` contain one, so percent-encode them (`plain/s3%3A%2F%2Fbucket%2Fkey`) or pass the source base64-encoded. Colons and `@` are fine.

Cache keys follow your imgproxy configuration (`Accept` with format detection, client hints, `IMGPROXY_CACHE_KEY_HEADERS` and `IMGPROXY_CACHE_KEY_COOKIES`). `secret_secret` cannot be combined with CloudFront, which does not forward `Authorization`. Query strings are not forwarded either, so percent-encode any `?` in plain source URLs.

### Vendored modules

`modules/aws-common` and `modules/imgproxy-common` are generated copies from `imgproxy/terraform-common`. Do not edit them here: change them upstream and run its `sync.sh`.

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
| terraform | n/a |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| aws\_common | ./modules/aws-common | n/a |
| imgproxy\_common | ./modules/imgproxy-common | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_ecr_lifecycle_policy.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_lifecycle_policy) | resource |
| [aws_ecr_repository.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_repository) | resource |
| [aws_ecr_repository_policy.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_repository_policy) | resource |
| [aws_lambda_alias.live](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_alias) | resource |
| [aws_lambda_function.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_function_url.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function_url) | resource |
| [aws_lambda_permission.cloudfront_url](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_lambda_permission.cloudfront_url_invoke](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_lambda_permission.public_url](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_lambda_permission.public_url_invoke](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_lambda_provisioned_concurrency_config.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_provisioned_concurrency_config) | resource |
| [aws_secretsmanager_secret.env](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_version.env](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_security_group.function](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [terraform_data.mirror](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_ecr_image.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ecr_image) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_secretsmanager_secret_version.env](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/secretsmanager_secret_version) | data source |

## Inputs

| Name | Description | Type | Required |
| ---- | ----------- | ---- | :------: |
| additional\_security\_group\_ids | Additional security group IDs to attach to the function. | `list(string)` | no |
| allow\_public\_access | Make the Function URL publicly callable (authorization NONE). When false, callers must sign requests with SigV4 (authorization AWS\_IAM). Ignored when enable\_cloudfront = true: CloudFront is then the only caller. | `bool` | no |
| architecture | Instruction set architecture of the function. arm64 (Graviton) is recommended: lower cost, same performance. The matching image platform is mirrored. | `string` | no |
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
| image\_uri | URI of an image that is already in ECR, in the same account and region. When set, nothing is mirrored and repo, tag, pro and repo\_credentials\_secret are ignored. Use it when the image is mirrored outside Terraform, or to pin an exact digest. | `string` | no |
| insecure | Disable URL signature checks. When true, key and salt are not required. | `bool` | no |
| keys\_secret | Secrets Manager ARN for imgproxy signing keys (comma-separated hex-encoded values). Required when insecure = false. Generate: openssl rand -hex 64. Sets IMGPROXY\_KEY. | ```object({ arn = string version = optional(string, "") })``` | no |
| log\_retention\_days | CloudWatch log group retention in days. | `number` | no |
| memory\_size | Memory in MB (128–10240). Lambda allocates CPU in proportion: about 1 vCPU per 1769 MB. | `number` | no |
| pro | Use imgproxy Pro (docker.imgproxy.pro) instead of the community image (ghcr.io) as the default repo. Has no effect when repo or image\_uri is set. | `bool` | no |
| pro\_license\_key\_secret | Secrets Manager ARN for the imgproxy Pro license key. Sets IMGPROXY\_LICENSE\_KEY. | ```object({ arn = string version = optional(string, "") })``` | no |
| provisioned\_concurrency | Number of pre-initialized instances kept warm, which removes cold starts for that many concurrent requests. When above 0, the function is published to a 'live' alias and the Function URL points at the alias. Billed continuously. | `number` | no |
| repo | Container repository to mirror imgproxy from, without tag (e.g. 'registry.example.com/imgproxy'). When null, 'pro' selects docker.imgproxy.pro/imgproxy or ghcr.io/imgproxy/imgproxy. Lambda can only run images stored in ECR, so the image is copied into an ECR repository created by this module, unless repo is already an ECR repository of this account and region (<account>.dkr.ecr.<region>.amazonaws.com/...): then it is used as it is and nothing is copied. Such an image must be a single-platform image for the function's architecture, and the repository must allow Lambda to pull it (see the README). | `string` | no |
| repo\_credentials\_secret | Secrets Manager secret with the credentials for the registry in 'repo' (or docker.imgproxy.pro when 'repo' is not set). Must be a JSON secret with 'username' and 'password' keys. Required when pro = true and repo is not set. Read by the machine running Terraform while mirroring the image, not by the function. | ```object({ arn = string })``` | no |
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
| tag | imgproxy image tag (version). Pin a version or a sha256: digest: the image is mirrored to ECR when the tag changes, not when the upstream tag moves. | `string` | no |
| tags | Tags applied to all created resources. | `map(string)` | no |
| timeout | imgproxy request timeout in seconds. Sets IMGPROXY\_TIMEOUT. Keep it below function\_timeout. | `number` | no |
| trusted\_signatures\_secret | Secrets Manager ARN for trusted signature prefixes. imgproxy Pro only. Sets IMGPROXY\_TRUSTED\_SIGNATURES. | ```object({ arn = string version = optional(string, "") })``` | no |
| vpc\_id | VPC ID to attach the function to. Only needed to reach private resources: the function then loses internet access unless the subnets route through a NAT gateway or VPC endpoints for S3 and Secrets Manager. When null, the function runs outside any VPC. | `string` | no |
| workers | Number of concurrent requests per function instance. Sets IMGPROXY\_WORKERS. Defaults to 1: Lambda hands one request at a time to each instance. | `number` | no |

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
| repository\_url | URL of the ECR repository the image is mirrored to (null when image\_uri is set). |
| role\_arn | ARN of the IAM role used by the function at runtime. |
| security\_group\_id | Security group ID attached to the function (null when not attached to a VPC). |
| url | imgproxy endpoint URL. CloudFront domain when enable\_cloudfront = true, otherwise the Function URL. |
<!-- END_TF_DOCS -->

## License

MIT
