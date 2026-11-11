#!/usr/bin/env bash
# Copies a container image into ECR for a single platform. Lambda only runs images
# stored in ECR and rejects multi-platform indexes, so one platform is copied.
#
# Usage: mirror-image.sh <source-image> <ecr-image> <region> <platform> [credentials-secret-arn]
#
# Needs: crane, aws CLI, and jq when a credentials secret is given.
set -euo pipefail

src="$1"
dst="$2"
region="$3"
platform="$4"
creds_secret="${5:-}"

for tool in crane aws; do
  command -v "$tool" >/dev/null || { echo "error: $tool is required to mirror the imgproxy image" >&2; exit 1; }
done

# Keep registry logins out of the user's Docker config.
DOCKER_CONFIG="$(mktemp -d)"
export DOCKER_CONFIG
trap 'rm -rf "$DOCKER_CONFIG"' EXIT

ecr_login() {
  aws ecr get-login-password --region "$1" |
    crane auth login "$2" --username AWS --password-stdin
}

src_host="${src%%/*}"
dst_host="${dst%%/*}"

ecr_login "$region" "$dst_host"

# A source in another ECR registry authenticates with the AWS credentials too.
if [[ "$src_host" =~ \.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com$ ]]; then
  ecr_login "${BASH_REMATCH[1]}" "$src_host"
elif [ -n "$creds_secret" ]; then
  command -v jq >/dev/null || { echo "error: jq is required to read repo_credentials_secret" >&2; exit 1; }
  secret="$(aws secretsmanager get-secret-value --region "$region" --secret-id "$creds_secret" --query SecretString --output text)"
  jq -r .password <<<"$secret" |
    crane auth login "$src_host" --username "$(jq -r .username <<<"$secret")" --password-stdin
fi

crane copy --platform "$platform" "$src" "$dst"
