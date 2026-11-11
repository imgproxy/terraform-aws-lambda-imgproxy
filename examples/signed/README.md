# Signed URLs

Production imgproxy with request signing, so only URLs signed with your key and salt are processed.

## AWS setup

You need an AWS account, the [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html),
authenticated, and [crane](https://github.com/google/go-containerregistry/blob/main/cmd/crane/README.md) (the module
copies the imgproxy image into ECR, because Lambda only runs ECR images):

```bash
aws configure
# or: aws sso login --profile my-profile && export AWS_PROFILE=my-profile
```

> The `aws` commands below use two profiles, set at the start of Prerequisites: `PROFILE_NAME` is the one Terraform uses, and `ADMIN_PROFILE_NAME` creates, reads and deletes the Secrets Manager secrets and the S3 buckets. They may be the same or different; drop the flags if you use the default credentials.
> `ADMIN_PROFILE_NAME` must be allowed `secretsmanager:CreateSecret`, `GetSecretValue` and `DeleteSecret`, or `aws secretsmanager create-secret` fails with `AccessDeniedException`. `PROFILE_NAME` does not need to create these secrets, but the Lambda module reads their values (`GetSecretValue`) and manages its own dotenv secret (see [Permissions](../../README.md#permissions)).
> An `aws: [ERROR]: An error occurred (ForbiddenException) when calling the GetRoleCredentials operation: No access` error usually means the profile is missing or wrong.

## Prerequisites

Create the signing keys and store them in Secrets Manager:

```bash
PROFILE_NAME=my-profile # AWS CLI profile used by Terraform; see AWS setup
ADMIN_PROFILE_NAME=$PROFILE_NAME # profile that creates the secrets and buckets; may differ, see AWS setup
REGION=us-east-1

aws secretsmanager create-secret --profile $ADMIN_PROFILE_NAME --region $REGION --name imgproxy-keys --secret-string "$(openssl rand -hex 64)"
aws secretsmanager create-secret --profile $ADMIN_PROFILE_NAME --region $REGION --name imgproxy-salts --secret-string "$(openssl rand -hex 64)"
```

## Deploy

```bash
echo "region = \"$REGION\"" > terraform.tfvars
echo "profile = \"$PROFILE_NAME\"" >> terraform.tfvars # AWS CLI profile used by Terraform; omit for default credentials

terraform init
terraform plan
terraform apply
```

Unsigned requests are rejected:

```bash
curl -I "$(terraform output -raw url)/insecure/plain/https://picsum.photos/200"   # 403 Forbidden
```

Print a signed URL (paste it into a browser):

```bash
(
URL=$(terraform output -raw url)
KEY=$(aws secretsmanager get-secret-value --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-keys --query SecretString --output text)
SALT=$(aws secretsmanager get-secret-value --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-salts --query SecretString --output text)
IMG_PATH="/rs:fit:300:300/plain/https://picsum.photos/1200/800.jpg"
SIG=$( (printf '%s' "$SALT" | xxd -r -p; printf '%s' "$IMG_PATH") \
  | openssl dgst -sha256 -mac HMAC -macopt hexkey:$KEY -binary \
  | openssl base64 -A | tr '+/' '-_' | tr -d '=' )
echo "$URL/$SIG$IMG_PATH"
)
```

This assumes a single key/salt pair. See [imgproxy's signing algorithm](https://docs.imgproxy.net/usage/signing_the_url) for details.

## Production setup

The Function URL is public and served over HTTPS by AWS, so unlike a load balancer there is no certificate to attach.
For production:

- **Cap the cost.** Anyone can request signed URLs you hand out, and each request is billed. Set
  `reserved_concurrency` to bound the function, and put [CloudFront](../cdn/) in front so repeated requests are served
  from cache instead of invoking the function.
- **Use your own domain** through CloudFront (`cloudfront_domains`). The Function URL itself has a generated hostname.
- **Private subnets only when needed.** The function runs outside any VPC by default, with internet access.
  Attach it with `vpc_id` and `subnet_ids` only to reach private resources, and give the subnets a **NAT gateway**
  (imgproxy fetches source images from the internet) or VPC endpoints for S3 and Secrets Manager. Add rules through
  the `security_group_id` output.
- **Pin the image tag** (a version or a `sha256:` digest), because the image is copied into ECR only when the tag changes.

The other examples keep the defaults for brevity; the same settings apply to all of them.

## Cleanup

```bash
terraform destroy
```

The secrets created in Prerequisites are not managed by Terraform; delete them separately:

```bash
aws secretsmanager delete-secret --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-keys --force-delete-without-recovery
aws secretsmanager delete-secret --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-salts --force-delete-without-recovery
```

## Next

Continue with [s3](../s3/).
