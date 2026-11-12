# Insecure mode

Minimal imgproxy on AWS Lambda with no request signing (`insecure = true`): community edition, default sizing, a public
Function URL, no monitoring and no S3. It fetches public placeholder images.

> [!WARNING]
> This example is intended for **development and testing only**. Without request signing anyone can use your
> imgproxy (unlimited bandwidth costs, no protection against abuse, no control over processed images). Never use
> this configuration in production.

## AWS setup

You need an AWS account, the [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html),
authenticated, and [Docker](https://docs.docker.com/get-docker/) (to push
the imgproxy image into ECR, because Lambda only runs ECR images):

```bash
aws configure
# or: aws sso login --profile my-profile && export AWS_PROFILE=my-profile
```

> The `aws` commands below use `--profile $PROFILE_NAME`, set at the start of Prerequisites: use your profile, or drop the flag if you use the default credentials.
> An `aws: [ERROR]: An error occurred (ForbiddenException) when calling the GetRoleCredentials operation: No access` error usually means the profile is missing or wrong.

## Prerequisites

```bash
PROFILE_NAME=my-profile # AWS CLI profile used by Terraform; see AWS setup
REGION=us-east-1
```

## Deploy

```bash
echo "region = \"$REGION\"" > terraform.tfvars
echo "profile = \"$PROFILE_NAME\"" >> terraform.tfvars # AWS CLI profile used by Terraform; omit for default credentials

terraform init

# 1. Create the ECR repository (Lambda runs ECR images only; the module does not create it)
terraform apply -target=aws_ecr_repository.imgproxy -target=aws_ecr_repository_policy.imgproxy

# 2. Push the image to it. The -arm64 tag is the single-platform build for Graviton, the default architecture
REPO_URL=$(terraform output -raw repository_url)
aws ecr get-login-password --profile $PROFILE_NAME --region $REGION | docker login --username AWS --password-stdin "${REPO_URL%%/*}"
docker pull ghcr.io/imgproxy/imgproxy:v4-arm64
docker tag ghcr.io/imgproxy/imgproxy:v4-arm64 "$REPO_URL:v4"
docker push "$REPO_URL:v4"

# 3. Deploy the function
terraform plan
terraform apply
```

Terraform creates the function, which takes a minute. Then print a ready-to-open URL
(paste it into a browser; no signature is required in insecure mode):

```bash
echo "$(terraform output -raw url)/insecure/rs:fit:300:300/plain/https://picsum.photos/1200/800.jpg"
```

The first request after a deploy (or after idle time) starts a new function instance, which takes a few seconds; later
requests are fast. `provisioned_concurrency` keeps instances warm: see [complete](../complete/).

## Cleanup

```bash
terraform destroy
```

## Next

Continue with [signed](../signed/).
