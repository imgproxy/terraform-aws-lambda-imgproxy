# CloudFront CDN

A CloudFront distribution in front of the Function URL, caching processed images at edge locations. A domain name is
optional: this example serves the CDN on its own `*.cloudfront.net` domain over HTTPS (see below for adding your own
domain). It fetches public placeholder images, so no bucket is needed.

## AWS setup

You need an AWS account, the [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html),
authenticated, and [Docker](https://docs.docker.com/get-docker/) (to push
the imgproxy image into ECR, because Lambda only runs ECR images):

```bash
aws configure
# or: aws sso login --profile my-profile && export AWS_PROFILE=my-profile
```

> - `PROFILE_NAME` is used by Terraform; `ADMIN_PROFILE_NAME` creates the secrets and buckets. They may be the same; drop `--profile` to use default credentials.
> - The admin profile needs Secrets Manager create/read/delete access (plus S3 where buckets are created); see [Permissions](../../README.md#permissions).
> - A `GetRoleCredentials ... No access` error means the profile is missing or wrong.

## Prerequisites

Create the signing keys (see [signed](../signed/)):

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

CloudFront takes 5-10 minutes to deploy. Print a signed URL for a placeholder image and request it twice:

```bash
(
URL=$(terraform output -raw url)
KEY=$(aws secretsmanager get-secret-value --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-keys --query SecretString --output text)
SALT=$(aws secretsmanager get-secret-value --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-salts --query SecretString --output text)
# Percent-encode the source URL: a double slash (//) in the path breaks the signed request from CloudFront to the Function URL (see CloudFront in the main README)
IMG_PATH="/rs:fit:300:300/plain/https%3A%2F%2Fpicsum.photos%2F1200%2F800.jpg"
SIG=$( (printf '%s' "$SALT" | xxd -r -p; printf '%s' "$IMG_PATH") \
  | openssl dgst -sha256 -mac HMAC -macopt hexkey:$KEY -binary \
  | openssl base64 -A | tr '+/' '-_' | tr -d '=' )
echo "$URL/$SIG$IMG_PATH"
)
```

```bash
# Repeated requests for the same URL: the second response says "Hit from cloudfront" and carries an Age header
curl -sI "<url from above>" | grep -i -E '^(HTTP|x-cache|age)'
```

## Adding a domain

In [main.tf](main.tf), uncomment `cloudfront_domains` and `cloudfront_certificate_arn`. This certificate must be issued
in **us-east-1** (an ACM requirement for CloudFront), whatever region the function runs in. After `terraform apply`,
point your domain at `terraform output cloudfront_domain_name` with a CNAME record, or with a Route 53 alias record
using `terraform output cloudfront_hosted_zone_id`. The `url` output then returns `https://<your domain>`.

## Locked-down origin

With CloudFront enabled, the Function URL requires IAM and its resource policy admits only your distribution
(Origin Access Control: CloudFront signs every origin request with SigV4). Direct requests to the Function URL are
rejected with `403`, so all traffic goes through the CDN. Unlike an ALB origin there is no secret header and no
origin certificate to set up.

Cache keys follow your imgproxy configuration: the `Accept` header is added when format detection
(`IMGPROXY_AUTO_WEBP`, `IMGPROXY_AUTO_AVIF`, ...) is enabled, the client hints headers with
`IMGPROXY_ENABLE_CLIENT_HINTS`, and so on. An authorization token (`secret_secret`) cannot be combined with
CloudFront, which does not forward the `Authorization` header.

## Cleanup

```bash
terraform destroy
```

The secrets were created with the AWS CLI, so delete them separately (and remove the DNS record if you added a domain):

```bash
aws secretsmanager delete-secret --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-keys --force-delete-without-recovery
aws secretsmanager delete-secret --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-salts --force-delete-without-recovery
```

## Next

Continue with [pro](../pro/).
