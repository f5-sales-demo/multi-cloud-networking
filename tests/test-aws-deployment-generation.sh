#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
aws_root="$repo_root/terraform"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_text() {
  local file=$1 text=$2
  grep -Fq -- "$text" "$file" || fail "${file#"$repo_root"/} is missing: $text"
}

variables="$aws_root/variables_ce.tf"
locals_file="$aws_root/locals.tf"
tgw="$aws_root/aws_tgw_connect.tf"
tgw_module="$repo_root/terraform/modules/aws-tgw-connect"
xc="$aws_root/aws_xc.tf"

require_text "$variables" 'variable "smsv2_site_generation" {'
generation_block=$(sed -n '/variable "smsv2_site_generation" {/,/^}/p' "$variables")
grep -Eq '^[[:space:]]*default[[:space:]]*=[[:space:]]*"smsv2"$' <<<"$generation_block" ||
  fail "smsv2_site_generation must use the documented smsv2 identity"
require_text "$variables" 'smsv2_site_generation must be a DNS-style label'
require_text "$locals_file" 'site_prefix_base = coalesce(var.site_prefix, "${var.component}-${var.smsv2_site_generation}")'
require_text "$locals_file" 'site_prefix      = local.deployment_is_production ? local.site_prefix_base : "mcn-${local.deployment_environment_key}"'
require_text "$locals_file" 'aws_resource_prefix = local.deployment_is_production ? local.site_prefix : "mcn${local.deployment_short_suffix}"'
require_text "$locals_file" '"mcn-deployment-generation" = var.smsv2_site_generation'

if rg -n '\$\{var\.component\}-aws' "$aws_root" --glob '*.tf'; then
  fail "an AWS/XC resource name or Name tag bypasses the immutable deployment generation"
fi
require_text "$tgw" 'name_prefix                = local.aws_resource_prefix'
require_text "$tgw" 'name        = "${local.aws_resource_prefix}-aws-tgw-${replace(each.key, "_", "-")}"'
require_text "$tgw" 'ownership_tags             = local.tags'
require_text "$tgw_module/variables.tf" 'variable "ownership_tags" {'
require_text "$tgw_module/main.tf" 'tags = merge(var.ownership_tags, {'

for resource in xcsh_token xcsh_securemesh_site_v2 xcsh_virtual_site xcsh_origin_pool xcsh_http_loadbalancer; do
  block=$(sed -n "/resource \"$resource\" /,/^}/p" "$xc")
  grep -Fq 'labels' <<<"$block" || fail "$resource must carry deployment-generation labels"
done
for resource in xcsh_external_connector xcsh_bgp; do
  block=$(sed -n "/resource \"$resource\" /,/^}/p" "$tgw")
  grep -Fq 'labels' <<<"$block" || fail "$resource must carry deployment-generation labels"
done

printf 'PASS: every AWS and XC identity follows the documented immutable SMSv2 generation\n'
