#!/usr/bin/env bash
# Run Terraform with AWS credentials exported by the AWS CLI's authenticated SSO
# cache. The isolated generated profile prevents stale static credentials in
# ~/.aws/credentials from shadowing the selected SSO profile in Terraform's AWS
# SDK. No credential value is written to disk.
set -euo pipefail

fail() {
  printf 'terraform-with-aws-sso: %s\n' "$*" >&2
  exit 1
}

validate_profile() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] ||
    fail "AWS profile names may contain only letters, digits, dots, underscores, and hyphens"
}

if [ "${1:-}" = "__export_credentials" ]; then
  [ "$#" -eq 4 ] || fail "invalid credential-process invocation"
  source_profile=$2
  source_config=$3
  aws_bin=$4
  validate_profile "$source_profile"
  [ -r "$source_config" ] || fail "AWS source config is not readable"
  [ -x "$aws_bin" ] || fail "AWS CLI executable is not available"
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
  export AWS_CONFIG_FILE="$source_config"
  export AWS_SHARED_CREDENTIALS_FILE=/dev/null
  export AWS_SDK_LOAD_CONFIG=1
  exec "$aws_bin" configure export-credentials \
    --profile "$source_profile" \
    --format process
fi

source_profile=${AWS_SSO_SOURCE_PROFILE:-default}
execute_command=false
region=${AWS_REGION:-${AWS_DEFAULT_REGION:-}}
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
  case "$1" in
  --exec)
    execute_command=true
    shift
    ;;
  --profile)
    [ "$#" -ge 2 ] || fail "--profile requires a value"
    source_profile=$2
    shift 2
    ;;
  --region)
    [ "$#" -ge 2 ] || fail "--region requires a value"
    region=$2
    shift 2
    ;;
  *) fail "usage: $0 [--profile NAME] [--region REGION] [--exec] -- ARGUMENTS..." ;;
  esac
done
[ "${1:-}" = "--" ] || fail "usage: $0 [--profile NAME] [--region REGION] [--exec] -- ARGUMENTS..."
shift
[ "$#" -gt 0 ] || fail "at least one Terraform argument is required"
validate_profile "$source_profile"

aws_bin=$(command -v aws) || fail "AWS CLI is unavailable"
terraform_bin=$(command -v terraform) || fail "Terraform is unavailable"
source_config=${MCN_AWS_SSO_SOURCE_CONFIG:-${AWS_CONFIG_FILE:-${HOME:?}/.aws/config}}
[ -r "$source_config" ] || fail "AWS source config is not readable: $source_config"
source_config=$(cd "$(dirname "$source_config")" && printf '%s/%s\n' "$PWD" "$(basename "$source_config")")
script_path=$(cd "$(dirname "${BASH_SOURCE[0]}")" && printf '%s/%s\n' "$PWD" "$(basename "${BASH_SOURCE[0]}")")

for path_value in "$aws_bin" "$source_config" "$script_path"; do
  [[ "$path_value" =~ ^/[A-Za-z0-9_./-]+$ ]] ||
    fail "credential-process paths may contain only safe absolute-path characters"
done

if [ -z "$region" ]; then
  region=$(AWS_CONFIG_FILE="$source_config" \
    AWS_SHARED_CREDENTIALS_FILE=/dev/null \
    AWS_SDK_LOAD_CONFIG=1 \
    "$aws_bin" configure get region --profile "$source_profile") ||
    fail "the selected SSO profile does not define a region"
fi
[[ "$region" =~ ^[a-z]{2}(-[a-z0-9]+)+-[0-9]+$ ]] || fail "resolved AWS region is invalid"

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/mcn-terraform-sso.XXXXXX")
trap 'rm -rf "$temporary_root"' EXIT
config_file="$temporary_root/config"
umask 077
printf '%s\n' \
  '[profile mcn-terraform]' \
  "credential_process = ${script_path} __export_credentials ${source_profile} ${source_config} ${aws_bin}" \
  "region = ${region}" \
  >"$config_file"

if [ "$execute_command" = true ]; then
  command_argv=("$@")
else
  command_argv=("$terraform_bin" "$@")
fi

set +e
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
MCN_AWS_SSO_SOURCE_CONFIG="$source_config" \
  AWS_SSO_SOURCE_PROFILE="$source_profile" \
  AWS_CONFIG_FILE="$config_file" \
  AWS_SHARED_CREDENTIALS_FILE=/dev/null \
  AWS_SDK_LOAD_CONFIG=1 \
  AWS_PROFILE=mcn-terraform \
  AWS_REGION="$region" \
  AWS_DEFAULT_REGION="$region" \
  "${command_argv[@]}"
status=$?
set -e
exit "$status"
