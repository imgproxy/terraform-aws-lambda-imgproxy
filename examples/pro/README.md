# imgproxy Pro

imgproxy Pro with a license key and an S3 result cache. It fetches public placeholder images, so no source bucket is
needed.

See [signed](../signed/#production-setup) for the production setup.

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

Create the imgproxy Pro license secret, the signing keys (see [signed](../signed/)), and a private bucket for the
result cache. The `docker.imgproxy.pro` registry credentials are only used by `docker login` when you push the image (see
Deploy), so they are not stored in Secrets Manager:

```bash
PROFILE_NAME=my-profile # AWS CLI profile used by Terraform; see AWS setup
ADMIN_PROFILE_NAME=$PROFILE_NAME # profile that creates the secrets and buckets; may differ, see AWS setup
REGION=us-east-1
ACCOUNT_ID=$(aws sts get-caller-identity --profile $PROFILE_NAME --query Account --output text)

aws secretsmanager create-secret --profile $ADMIN_PROFILE_NAME --region $REGION --name imgproxy-pro-license --secret-string "your-license-key"

aws secretsmanager create-secret --profile $ADMIN_PROFILE_NAME --region $REGION --name imgproxy-keys --secret-string "$(openssl rand -hex 64)"
aws secretsmanager create-secret --profile $ADMIN_PROFILE_NAME --region $REGION --name imgproxy-salts --secret-string "$(openssl rand -hex 64)"

aws s3 mb --profile $ADMIN_PROFILE_NAME s3://$ACCOUNT_ID-imgproxy-cache --region $REGION
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
# imgproxy Pro: log in to its registry first (the username is imgproxy)
docker login docker.imgproxy.pro --username imgproxy --password-stdin <<< "your-registry-password"
docker pull docker.imgproxy.pro/imgproxy:v4-arm64
docker tag docker.imgproxy.pro/imgproxy:v4-arm64 "$REPO_URL:v4"
docker push "$REPO_URL:v4"

# 3. Deploy the function
terraform plan
terraform apply
```

Print a signed URL for a placeholder image (see [signed](../signed/) for how signing works) and open it:

```bash
(
URL=$(terraform output -raw url)
KEY=$(aws secretsmanager get-secret-value --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-keys --query SecretString --output text)
SALT=$(aws secretsmanager get-secret-value --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-salts --query SecretString --output text)
IMG_PATH="/rs:fit:300:200/plain/https://picsum.photos/1200/800.jpg"
SIG=$( (printf '%s' "$SALT" | xxd -r -p; printf '%s' "$IMG_PATH") \
  | openssl dgst -sha256 -mac HMAC -macopt hexkey:$KEY -binary \
  | openssl base64 -A | tr '+/' '-_' | tr -d '=' )
echo "$URL/$SIG$IMG_PATH"
)
```

imgproxy Pro caches processed results in the cache bucket (`cache_bucket`, Pro only), so repeated requests are
served faster. Request the URL printed above with `curl` and look for the `X-Imgproxy-Cache` response header:

```bash
curl -s -D- -o /dev/null "<url from above>" | grep -i x-imgproxy-cache
# A request for a new URL is processed and stored; repeating it returns "x-imgproxy-cache: Hit"
```

The processed results are stored in the cache bucket:

```bash
aws s3 ls --profile $ADMIN_PROFILE_NAME s3://$ACCOUNT_ID-imgproxy-cache --recursive
```

## Using another image

The module runs whatever is in your ECR repository: push another image (your own build, or a copy of the Pro image
from your registry) into it and set `tag`, or point at an exact image with `image_uri`:

```hcl
tag = "my-tag"
# or
image_uri = "123456789012.dkr.ecr.us-east-1.amazonaws.com/imgproxy-pro@sha256:..."
```

The image must be in ECR in the function's region and single-platform. The function runs on arm64 (Graviton) by
default, so use the `-arm64` image; for `architecture = "x86_64"` use the `-amd64` one.

## Cleanup

```bash
terraform destroy
```

The bucket and the secrets were created with the AWS CLI, so delete them separately:

```bash
aws s3 rb --profile $ADMIN_PROFILE_NAME s3://$ACCOUNT_ID-imgproxy-cache --force
aws secretsmanager delete-secret --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-pro-license --force-delete-without-recovery
aws secretsmanager delete-secret --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-keys --force-delete-without-recovery
aws secretsmanager delete-secret --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-salts --force-delete-without-recovery
```

## Next

Continue with [complete](../complete/).
