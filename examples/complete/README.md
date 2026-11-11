# Complete imgproxy Deployment Example

This example demonstrates a full-featured imgproxy deployment on AWS Lambda with all available features:

- imgproxy Pro with license key
- Request signing with configurable key size
- Source URL encryption
- Authorization token (Bearer auth)
- X-Ray tracing and CloudWatch metrics
- S3 integration for source images and result cache
- CloudFront CDN with a global edge cache
- Provisioned and reserved concurrency
- Optional VPC attachment (commented out)
- Additional secrets for third-party integrations
- Custom memory, timeouts and ephemeral storage
- Resource tags

## AWS setup

You need an AWS account, the [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html),
authenticated, and [crane](https://github.com/google/go-containerregistry/blob/main/cmd/crane/README.md) (the module
copies the imgproxy image into ECR, because Lambda only runs ECR images):

```bash
aws configure
# or: aws sso login --profile my-profile && export AWS_PROFILE=my-profile
```

> The `aws` commands below use two profiles, set at the start of Prerequisites: `PROFILE_NAME` is the one Terraform uses, and `ADMIN_PROFILE_NAME` creates, reads and deletes the Secrets Manager secrets and the S3 buckets. They may be the same or different; drop the flags if you use the default credentials.
> `ADMIN_PROFILE_NAME` must be allowed `secretsmanager:CreateSecret`, `GetSecretValue` and `DeleteSecret` (and S3 bucket and object management for the buckets), or `aws secretsmanager create-secret` fails with `AccessDeniedException`. `PROFILE_NAME` does not need to create these secrets, but the Lambda module reads their values (`GetSecretValue`) and manages its own dotenv secret (see [Permissions](../../README.md#permissions)).
> An `aws: [ERROR]: An error occurred (ForbiddenException) when calling the GetRoleCredentials operation: No access` error usually means the profile is missing or wrong.

## Prerequisites

**Create Secrets Manager secrets and S3 buckets:**

```bash
PROFILE_NAME=my-profile # AWS CLI profile used by Terraform; see AWS setup
ADMIN_PROFILE_NAME=$PROFILE_NAME # profile that creates the secrets and buckets; may differ, see AWS setup
REGION=us-east-1
ACCOUNT_ID=$(aws sts get-caller-identity --profile $PROFILE_NAME --query Account --output text)

# Signing keys (required)
aws secretsmanager create-secret --profile $ADMIN_PROFILE_NAME --region $REGION --name imgproxy-keys --secret-string "$(openssl rand -hex 64)"
aws secretsmanager create-secret --profile $ADMIN_PROFILE_NAME --region $REGION --name imgproxy-salts --secret-string "$(openssl rand -hex 64)"

# imgproxy Pro (if using pro = true); the registry secret is JSON, for docker.imgproxy.pro or for your own registry set via repo
aws secretsmanager create-secret --profile $ADMIN_PROFILE_NAME --region $REGION --name imgproxy-pro-license --secret-string "your-license-key"
aws secretsmanager create-secret --profile $ADMIN_PROFILE_NAME --region $REGION --name imgproxy-pro-registry \
  --secret-string '{"username":"imgproxy","password":"your-registry-password"}'

# Optional: authorization token (Bearer auth; cannot be used together with CloudFront)
aws secretsmanager create-secret --profile $ADMIN_PROFILE_NAME --region $REGION --name imgproxy-secret --secret-string "$(openssl rand -hex 32)"

# Optional: source URL encryption key
aws secretsmanager create-secret --profile $ADMIN_PROFILE_NAME --region $REGION --name imgproxy-source-url-key --secret-string "$(openssl rand -hex 16)"

# S3 buckets for source images and the result cache (not managed by Terraform)
aws s3 mb --profile $ADMIN_PROFILE_NAME s3://$ACCOUNT_ID-imgproxy-complete-source --region $REGION
aws s3 mb --profile $ADMIN_PROFILE_NAME s3://$ACCOUNT_ID-imgproxy-complete-cache --region $REGION
```

## Deploy

Everything is configured in [main.tf](main.tf); edit it to enable the commented-out options (Bearer auth, source URL
encryption, trusted signatures, extra secrets, a custom registry or an existing ECR image, a VPC, CloudFront with a
domain).

See [signed](../signed/#production-setup) for the production setup. `jq` is needed to read the registry credentials.

1. **Deploy:**

```bash
echo "region = \"$REGION\"" > terraform.tfvars
echo "profile = \"$PROFILE_NAME\"" >> terraform.tfvars # AWS CLI profile used by Terraform; omit for default credentials

terraform init
terraform plan
terraform apply
```

2. **Access the service:**

```bash
terraform output url
```

3. **If you added a domain, point DNS:**

```bash
# The CloudFront domain, for the public domain (cdn.example.com)
terraform output cloudfront_domain_name

# Create a CNAME record (or a Route 53 alias record). The CloudFront certificate must be issued in us-east-1.
```

## Testing S3 Integration

Upload a test image to the source bucket:

```bash
aws s3 cp --profile $ADMIN_PROFILE_NAME test-image.jpg s3://$ACCOUNT_ID-imgproxy-complete-source/photo.jpg
```

Then access it via imgproxy using a signed URL:

```bash
(
URL=$(terraform output -raw url)
KEY=$(aws secretsmanager get-secret-value --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-keys --query SecretString --output text)
SALT=$(aws secretsmanager get-secret-value --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-salts --query SecretString --output text)
# Percent-encode the source URL: a double slash (//) in the path breaks the signed request from CloudFront to the Function URL (see CloudFront in the main README)
IMG_PATH="/plain/s3%3A%2F%2F$ACCOUNT_ID-imgproxy-complete-source%2Fphoto.jpg"
SIG=$( (printf '%s' "$SALT" | xxd -r -p; printf '%s' "$IMG_PATH") \
  | openssl dgst -sha256 -mac HMAC -macopt hexkey:$KEY -binary \
  | openssl base64 -A | tr '+/' '-_' | tr -d '=' )
echo "$URL/$SIG$IMG_PATH"
)
```

## Verifying Monitoring

After deployment with `enable_monitoring = true`, verify telemetry is flowing:

1. Go to AWS Console → X-Ray → Traces and confirm new traces appear for imgproxy requests
2. Go to AWS Console → CloudWatch → Metrics → All metrics → Custom namespaces → `imgproxy` (metrics appear within a
   minute or two of the first requests)
3. Go to AWS Console → CloudWatch → Log groups and open the group printed by `terraform output log_group_name`
4. Go to AWS Console → Lambda → `imgproxy` → Configuration → Concurrency and confirm 2 provisioned instances are
   ready (they take a minute or two to initialize after the first deploy)

## Cleanup

```bash
terraform destroy
```

The buckets and the secrets were created with the AWS CLI, so delete them separately (and remove the DNS record if you added a domain):

```bash
aws s3 rb --profile $ADMIN_PROFILE_NAME s3://$ACCOUNT_ID-imgproxy-complete-source --force
aws s3 rb --profile $ADMIN_PROFILE_NAME s3://$ACCOUNT_ID-imgproxy-complete-cache --force
aws secretsmanager delete-secret --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-pro-license --force-delete-without-recovery
aws secretsmanager delete-secret --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-pro-registry --force-delete-without-recovery
aws secretsmanager delete-secret --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-keys --force-delete-without-recovery
aws secretsmanager delete-secret --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-salts --force-delete-without-recovery
aws secretsmanager delete-secret --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-secret --force-delete-without-recovery
aws secretsmanager delete-secret --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-source-url-key --force-delete-without-recovery
```
