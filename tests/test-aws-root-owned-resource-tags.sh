#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_block() {
  local resource=$1
  local source_file=$2
  local block
  [[ -f $source_file ]] || fail "Azure-free AWS root is missing ${source_file##*/}"
  block=$(sed -n "/resource \\\"aws_iam_instance_profile\\\" \\\"${resource}\\\" {/,/^}/p" "$source_file")
  grep -Eq '^[[:space:]]*tags[[:space:]]*=[[:space:]]*local\.tags$' <<<"$block" ||
    fail "aws_iam_instance_profile.${resource} must carry the standard ownership tags"
}

require_block ce "$repo_root/terraform/aws_ce.tf"
require_block workload "$repo_root/terraform/aws_vpc.tf"

require_tgw_module_ownership_tags() {
  local source_file=$1
  local block
  block=$(sed -n '/module \"aws_tgw_connect\" {/,/^}/p' "$source_file")
  grep -Eq '^[[:space:]]*ownership_tags[[:space:]]*=[[:space:]]*local\.tags$' <<<"$block" ||
    fail "aws_tgw_connect in ${source_file#"${repo_root}"/} must pass immutable ownership tags"
}

require_tgw_module_ownership_tags "$repo_root/terraform/aws_tgw_connect.tf"

# Ownership labels come from configuration, while the separate ambient guard
# remains evaluated through its diagnostic output.
locals_file="$repo_root/terraform/locals.tf"
grep -Fq '"mcn-xc-tenant"             = var.expected_xc_tenant' "$locals_file" ||
  fail "XC labels must carry the configured XC tenant"
grep -Fq 'value       = data.external.xc_env_tenant.result.tenant' "$repo_root/terraform/outputs.tf" ||
  fail "the ambient-tenant guard must remain part of the evaluated graph"

printf 'PASS: AWS ownership metadata uses the configured tenant and evaluates the ambient guard\n'
