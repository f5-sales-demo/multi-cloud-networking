#!/usr/bin/env bash
# The unified lifecycle must produce an AWS-only plan with zero Azure/KVM actions.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)
providers="$root/providers.tf"
grep -Fq 'subscription_id            = local.azure_provider_enabled ? var.subscription_id : null' "$providers" ||
  {
    printf 'disabled Azure must not bind a stale subscription\n' >&2
    exit 1
  }
grep -Fq 'skip_provider_registration = !local.azure_provider_enabled' "$providers" ||
  {
    printf 'disabled Azure must not register resource providers\n' >&2
    exit 1
  }
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
data_dir=$(mktemp -d)
trap "rm -rf \"$data_dir\"" EXIT

TF_DATA_DIR="$data_dir" terraform -chdir="$root" init \
  -backend=false -input=false -lockfile=readonly >/dev/null
TF_DATA_DIR="$data_dir" terraform -chdir="$root" test \
  -filter=tests/aws_only_plan.tftest.hcl -no-color

printf "PASS: unified root can plan AWS with zero Azure and KVM resources\\n"
