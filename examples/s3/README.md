# S3 source bucket

imgproxy reading source images from a private S3 bucket via the `s3://` URL scheme. The module grants `s3:GetObject`
and `s3:ListBucket` on the bucket to the function role, so the bucket stays private.

See [signed](../signed/#production-setup) for the production setup.

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

Create the signing keys and a private bucket for source images (see [signed](../signed/) for the keys). Bucket names
are global, so the example prefixes it with your account ID:

```bash
PROFILE_NAME=my-profile # AWS CLI profile used by Terraform; see AWS setup
ADMIN_PROFILE_NAME=$PROFILE_NAME # profile that creates the secrets and buckets; may differ, see AWS setup
REGION=us-east-1
ACCOUNT_ID=$(aws sts get-caller-identity --profile $PROFILE_NAME --query Account --output text)

aws secretsmanager create-secret --profile $ADMIN_PROFILE_NAME --region $REGION --name imgproxy-keys --secret-string "$(openssl rand -hex 64)"
aws secretsmanager create-secret --profile $ADMIN_PROFILE_NAME --region $REGION --name imgproxy-salts --secret-string "$(openssl rand -hex 64)"

aws s3 mb --profile $ADMIN_PROFILE_NAME s3://$ACCOUNT_ID-imgproxy-images --region $REGION
```

## Deploy

```bash
echo "region = \"$REGION\"" > terraform.tfvars
echo "profile = \"$PROFILE_NAME\"" >> terraform.tfvars # AWS CLI profile used by Terraform; omit for default credentials

terraform init
terraform plan
terraform apply
```

```bash
aws s3 cp --profile $ADMIN_PROFILE_NAME photo.jpg s3://$ACCOUNT_ID-imgproxy-images/photo.jpg
```

Sign the request as in [signed](../signed/), with `IMG_PATH` pointing at the bucket object:

```bash
(
URL=$(terraform output -raw url)
KEY=$(aws secretsmanager get-secret-value --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-keys --query SecretString --output text)
SALT=$(aws secretsmanager get-secret-value --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-salts --query SecretString --output text)
IMG_PATH="/rs:fit:300:200/plain/s3://$ACCOUNT_ID-imgproxy-images/photo.jpg"
SIG=$( (printf '%s' "$SALT" | xxd -r -p; printf '%s' "$IMG_PATH") \
  | openssl dgst -sha256 -mac HMAC -macopt hexkey:$KEY -binary \
  | openssl base64 -A | tr '+/' '-_' | tr -d '=' )
echo "$URL/$SIG$IMG_PATH"
)
```

The module does not create buckets: it only grants the function role read access to the ones you list in `source_buckets`.
`IMGPROXY_S3_REGION` in `environment` tells imgproxy which region the bucket is in; set it to the bucket's region if
it differs from the one the function runs in.

## Cleanup

```bash
terraform destroy
```

The bucket and the secrets were created with the AWS CLI, so delete them separately:

```bash
aws s3 rb --profile $ADMIN_PROFILE_NAME s3://$ACCOUNT_ID-imgproxy-images --force
aws secretsmanager delete-secret --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-keys --force-delete-without-recovery
aws secretsmanager delete-secret --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-salts --force-delete-without-recovery
```

## Next

Continue with [cdn](../cdn/).
