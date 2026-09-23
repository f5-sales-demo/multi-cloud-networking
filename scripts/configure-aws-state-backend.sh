#!/usr/bin/env bash
# Generate the two non-secret backend configurations and migrate bootstrap state
# after the backend resources have been created by an inspected saved plan.
set -euo pipefail

fail() {
  printf 'configure-aws-state-backend: %s\n' "$*" >&2
  exit 1
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
wrapper="$repo_root/scripts/terraform-with-aws-sso.sh"
bootstrap_dir="$repo_root/terraform/bootstrap/state-backend"
metadata="$bootstrap_dir/.terraform/terraform.tfstate"
bootstrap_hcl="$bootstrap_dir/backend.hcl"
aws_hcl="$repo_root/terraform/backend.hcl"
recovery_hcl="$repo_root/terraform/recovery/aws-smsv2-orphans/backend.hcl"
backend_block="$bootstrap_dir/backend.generated.tf"
profile=default
requested_region=
source_repository=f5-sales-demo/multi-cloud-networking
source_ref=
source_commit_sha=
deployment_owner_id=
deployment_actor_id=

while [ "$#" -gt 0 ]; do
  case "$1" in
  --profile)
    [ "$#" -ge 2 ] || fail "--profile requires a value"
    profile=$2
    shift 2
    ;;
  --region)
    [ "$#" -ge 2 ] || fail "--region requires a value"
    requested_region=$2
    shift 2
    ;;
  --source-repository)
    [ "$#" -ge 2 ] || fail "--source-repository requires a value"
    source_repository=$2
    shift 2
    ;;
  --source-ref)
    [ "$#" -ge 2 ] || fail "--source-ref requires a value"
    source_ref=$2
    shift 2
    ;;
  --source-commit-sha)
    [ "$#" -ge 2 ] || fail "--source-commit-sha requires a value"
    source_commit_sha=$2
    shift 2
    ;;
  --deployment-owner-id)
    [ "$#" -ge 2 ] || fail "--deployment-owner-id requires a value"
    deployment_owner_id=$2
    shift 2
    ;;
  --deployment-actor-id)
    [ "$#" -ge 2 ] || fail "--deployment-actor-id requires a value"
    deployment_actor_id=$2
    shift 2
    ;;
  *) fail "usage: $0 [--profile NAME] [--region REGION] --source-ref REF --source-commit-sha SHA --deployment-owner-id ID --deployment-actor-id ID" ;;
  esac
done

[ -x "$wrapper" ] || fail "Terraform AWS SSO wrapper is not executable"
[ -n "$source_ref" ] || fail "--source-ref is required"
[ -n "$source_commit_sha" ] || fail "--source-commit-sha is required"
[ -n "$deployment_owner_id" ] || fail "--deployment-owner-id is required"
[ -n "$deployment_actor_id" ] || fail "--deployment-actor-id is required"
command -v jq >/dev/null || fail "jq is unavailable"
aws_bin=$(command -v aws) || fail "AWS CLI is unavailable"
identity_json=$(
  "$repo_root/scripts/deployment-identity.py" \
    --repository "$source_repository" \
    --source-ref "$source_ref" \
    --source-commit "$source_commit_sha" \
    --owner-id "$deployment_owner_id" \
    --actor-id "$deployment_actor_id"
) || fail "deployment identity is invalid"
showcase_backend_key=$(jq -er '.stateKey' <<<"$identity_json") || fail "showcase backend key is missing"
recovery_backend_key=$(jq -er '.recoveryStateKey' <<<"$identity_json") || fail "recovery backend key is missing"
unset identity_json

work=$(mktemp -d "${TMPDIR:-/tmp}/mcn-backend-config.XXXXXX")
trap 'rm -rf "$work"' EXIT
config_json="$work/backend.json"
migration_mode=-force-copy

if [ -s "$metadata" ] && jq -e '.backend.type == "s3"' "$metadata" >/dev/null 2>&1; then
  jq -e '.backend.config | {
    bucket,
    key,
    region,
    encrypt,
    kms_key_id,
    use_lockfile
  }' "$metadata" >"$config_json" || fail "existing backend metadata is incomplete"
  migration_mode=-reconfigure
else
  # A failed initial migration can leave the generated backend declaration in
  # place while Terraform still records local state. Remove only that generated
  # file so the local output remains readable and the operation can be retried.
  rm -f "$backend_block"
  output_json="$work/output.json"
  wrapper_options=(--profile "$profile")
  if [ -n "$requested_region" ]; then
    wrapper_options+=(--region "$requested_region")
  fi
  "$wrapper" "${wrapper_options[@]}" -- \
    -chdir="$bootstrap_dir" output -json >"$output_json"
  jq -e '.bootstrap_backend_hcl.value' "$output_json" >"$config_json" ||
    fail "bootstrap_backend_hcl output is missing"
fi

bucket=$(jq -er '.bucket' "$config_json") || fail "backend bucket is missing"
key=$(jq -er '.key' "$config_json") || fail "backend key is missing"
region=$(jq -er '.region' "$config_json") || fail "backend region is missing"
kms_key_id=$(jq -er '.kms_key_id' "$config_json") || fail "backend KMS key is missing"
jq -e '.encrypt == true and .use_lockfile == true' "$config_json" >/dev/null ||
  fail "backend encryption and native locking must both be enabled"

[[ "$bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || fail "backend bucket is invalid"
[ "$key" = "mcn-ce-ha-smsv2/bootstrap.tfstate" ] || fail "unexpected bootstrap state key"
[[ "$region" =~ ^[a-z]{2}(-[a-z0-9]+)+-[0-9]+$ ]] || fail "backend region is invalid"
[[ "$kms_key_id" =~ ^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$ ]] ||
  fail "backend KMS key ARN is invalid"

expected_account=$(printf '%s\n' "$kms_key_id" | awk -F: '{print $5}')
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
caller_account=$(
  AWS_SHARED_CREDENTIALS_FILE=/dev/null \
    AWS_SDK_LOAD_CONFIG=1 \
    "$aws_bin" sts get-caller-identity --profile "$profile" --query Account --output text
) || fail "AWS identity verification failed"
[ "$caller_account" = "$expected_account" ] || fail "AWS identity does not own the backend KMS key"

write_backend_hcl() {
  target=$1
  backend_key=$2
  temporary=$(mktemp "${target}.tmp.XXXXXX")
  chmod 600 "$temporary"
  printf '%s\n' \
    "bucket       = \"$bucket\"" \
    "key          = \"$backend_key\"" \
    "region       = \"$region\"" \
    'encrypt      = true' \
    "kms_key_id   = \"$kms_key_id\"" \
    'use_lockfile = true' \
    >"$temporary"
  mv "$temporary" "$target"
}

write_backend_hcl "$bootstrap_hcl" "$key"
write_backend_hcl "$aws_hcl" "$showcase_backend_key"
write_backend_hcl "$recovery_hcl" "$recovery_backend_key"

temporary_block=$(mktemp "${backend_block}.tmp.XXXXXX")
chmod 600 "$temporary_block"
printf '%s\n' 'terraform {' '  backend "s3" {}' '}' >"$temporary_block"
mv "$temporary_block" "$backend_block"

"$wrapper" --profile "$profile" --region "$region" -- \
  -chdir="$bootstrap_dir" init "$migration_mode" -input=false -backend-config=backend.hcl

jq -e \
  --arg bucket "$bucket" \
  --arg key "$key" \
  --arg region "$region" \
  --arg kms_key_id "$kms_key_id" \
  '.backend.type == "s3" and
   .backend.config.bucket == $bucket and
   .backend.config.key == $key and
   .backend.config.region == $region and
   .backend.config.kms_key_id == $kms_key_id and
   .backend.config.encrypt == true and
   .backend.config.use_lockfile == true' \
  "$metadata" >/dev/null || fail "Terraform backend metadata does not match the generated configuration"

printf 'AWS backend configured: verified_identity=true region=%s bucket=%s bootstrap_key=%s showcase_key=%s recovery_key=%s\n' \
  "$region" "$bucket" "$key" "$showcase_backend_key" "$recovery_backend_key"
