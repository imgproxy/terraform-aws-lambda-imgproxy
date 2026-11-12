# Signed URLs

Production imgproxy with request signing, so only URLs signed with your key and salt are processed.

## AWS setup

You need an AWS account, the [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html),
authenticated, and [Docker](https://docs.docker.com/get-docker/) (to push
the imgproxy image into ECR, because Lambda only runs ECR images):

```bash
aws configure
# or: aws sso login --profile my-profile && export AWS_PROFILE=my-profile
```

> [!NOTE]
> - `PROFILE_NAME` is used by Terraform; `ADMIN_PROFILE_NAME` creates the secrets and buckets. They may be the same; drop `--profile` to use default credentials.
> - The admin profile needs Secrets Manager create/read/delete access (plus S3 where buckets are created); see [Permissions](../../README.md#permissions).
> - A `GetRoleCredentials ... No access` error means the profile is missing or wrong.

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

# 1. Create the ECR repository (Lambda runs ECR images only; the module does not create it)
terraform apply -target=aws_ecr_repository.imgproxy

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
- **Pin the image tag** (a version or a `sha256:` digest): the function runs the image behind the tag in your ECR
  repository, so a new imgproxy release is deployed only when you copy it there and change `tag`.

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
