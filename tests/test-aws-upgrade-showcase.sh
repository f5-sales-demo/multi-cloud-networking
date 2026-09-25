#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)

require_text() {
  local file=$1 text=$2
  grep -Fq -- "$text" "${REPO_ROOT}/${file}" || {
    printf 'missing %s in %s\n' "$text" "$file" >&2
    exit 1
  }
}

reject_text() {
  local file=$1 text=$2
  if grep -Fq -- "$text" "${REPO_ROOT}/${file}"; then
    printf 'unexpected %s in %s\n' "$text" "$file" >&2
    exit 1
  fi
}

require_text terraform/versions.tf 'required_version = "= 1.16.3"'
require_text terraform/versions.tf 'version = "= 11.3.0"'
require_text terraform/aws_xc.tf 'disable_ha                 = {}'
require_text terraform/aws_xc.tf 'cluster_size = 1'
## A ground-up CE must request the field-proven runtime pair on its first boot.
## Requiring the old showcase baseline first leaves every new site UPGRADING
## before the later action-based upgrade stage can run.
require_text terraform/aws_xc.tf 'operating_system_version = var.aws_os_version'
require_text terraform/aws_xc.tf 'volterra_software_version = var.aws_software_version'
reject_text terraform/aws_xc.tf 'aws_baseline_'
require_text terraform/aws_xc.tf 'name      = "${local.aws_resource_prefix}-aws-vsite"'
require_text terraform/aws_xc.tf 'dynamic "advertise_where" {'
require_text terraform/aws_xc.tf 'for_each = var.aws_site_configuration_phase == "configured" ? local.aws_sites : local.aws_bootstrap_sites'
require_text terraform/aws_xc.tf 'site {'
reject_text terraform/aws_xc.tf 'ip      = var.aws_vip'
require_text terraform/aws_xc.tf 'network = "SITE_NETWORK_INSIDE"'
aws_lb=$(sed -n '/resource "xcsh_http_loadbalancer" "aws" {/,/^}/p' terraform/aws_xc.tf)
if grep -Eq 'virtual_site(_with_vip)?[[:space:]]*\{' <<<"$aws_lb"; then
  echo "AWS LB does not bind its VIP to the exact SMSv2 sites" >&2
  exit 1
fi
require_text terraform/aws_xc.tf 'default_sli_config = {}'
reject_text terraform/aws_xc.tf 'sli_config {'
reject_text terraform/aws_xc.tf 'vip_vrrp_mode'
reject_text terraform/variables_aws.tf 'variable "aws_vip_route_cidr" {'
reject_text terraform/aws_tgw_connect.tf 'advertise_vip_aggregate'
reject_text terraform/aws_tgw_connect.tf 'aggregation {'
reject_text terraform/aws_tgw_connect.tf 'resource "xcsh_bgp_routing_policy" "aws_vip_export" {'
reject_text terraform/aws_tgw_connect.tf 'routing_policies {'
bgp_status=$(sed -n '/data "xcsh_site_bgp_status" "aws" {/,/^}/p' terraform/aws_tgw_connect.tf)
grep -Fq 'timeout_seconds          = var.aws_bgp_convergence_timeout_seconds' <<<"$bgp_status" || {
  printf 'BGP status must use the provider-bounded BGP convergence timeout\n' >&2
  exit 1
}
for dependency in \
  'module.aws_tgw_connect' \
  'aws_ec2_transit_gateway_route_table_association.workload' \
  'aws_ec2_transit_gateway_route_table_propagation.workload' \
  'xcsh_http_loadbalancer.aws'; do
  grep -Fq "$dependency" <<<"$bgp_status" || {
    printf 'BGP status must wait for %s before enforcing exact route convergence\n' "$dependency" >&2
    exit 1
  }
done
require_text terraform/aws_ce.tf 'xcsh_site_cloud_init.aws'
runtime_timeout=$(sed -n '/variable "aws_runtime_convergence_timeout_seconds" {/,/^}/p' terraform/variables_aws.tf)
grep -Fq 'default     = 7200' <<<"$runtime_timeout" || {
  printf 'Runtime readiness must retain the full 7200-second first-boot budget\n' >&2
  exit 1
}
bgp_timeout=$(sed -n '/variable "aws_bgp_convergence_timeout_seconds" {/,/^}/p' terraform/variables_aws.tf)
grep -Fq 'default     = 1800' <<<"$bgp_timeout" || {
  printf 'BGP convergence must use the provider maximum 1800-second budget\n' >&2
  exit 1
}
require_text terraform/aws_xc.tf 'resource "xcsh_token" "aws"'
require_text terraform/aws_xc.tf 'type        = 1'
require_text terraform/aws_xc.tf 'site_name   = xcsh_securemesh_site_v2.aws[each.key].name'
require_text terraform/aws_xc.tf 'provider_ref              = "aws"'
runtime_observation=$(sed -n '/data "xcsh_smsv2_aws_runtime" "aws" {/,/^}/p' terraform/aws_tgw_connect.tf)
grep -Fq 'timeout_seconds       = var.aws_runtime_convergence_timeout_seconds' <<<"$runtime_observation" || {
  printf 'AWS runtime observation must retain the full first-boot convergence timeout\n' >&2
  exit 1
}
grep -Fq 'depends_on = [aws_instance.ce]' <<<"$runtime_observation" || {
  printf 'AWS runtime observation must wait for CE instances before polling F5 runtime health\n' >&2
  exit 1
}
upgrade_observation=$(sed -n '/data "xcsh_site_upgrade_status" "aws" {/,/^}/p' terraform/aws_upgrade.tf)
grep -Fq 'depends_on = [terraform_data.aws_tgw_runtime_gate]' <<<"$upgrade_observation" || {
  printf 'AWS upgrade observation must wait for the authoritative runtime gate before polling F5 upgrade status\n' >&2
  exit 1
}
require_text terraform/aws_ce.tf '"{{ .token }}"'
require_text terraform/aws_ce.tf 'aws_ce_site_cloud_init = {'
require_text terraform/aws_ce.tf 'try(xcsh_token.aws[key].uid, "{{ .token }}")'
require_text terraform/aws_ce.tf 'site_cloud_init = local.aws_ce_site_cloud_init[format("%02d", count.index + 1)]'
require_text terraform/aws_ce.tf 'software_version = var.aws_software_version'
require_text terraform/aws_ce.tf 'os_version       = var.aws_os_version'
require_text terraform/aws_ce.tf 'var.aws_ssh_public_key != "" ? var.aws_ssh_public_key : local.ssh_public_key'
reject_text terraform/aws_ce.tf 'aws_site_cloud_init = {'
require_text terraform/cloud-init/ce-node-aws.multipart.tpl 'multipart/mixed'
require_text terraform/cloud-init/ce-node-aws.multipart.tpl 'SLI_MAC='
require_text terraform/cloud-init/ce-node-aws.multipart.tpl 'Content-Type: text/cloud-config'
require_text terraform/cloud-init/ce-node-aws.multipart.tpl '${site_cloud_init}'
require_text terraform/cloud-init/ce-node-aws.multipart.tpl 'Content-Type: text/x-shellscript'
require_text terraform/cloud-init/ce-node-aws.multipart.tpl 'hostnamectl set-hostname "${fqdn}"'
require_text terraform/cloud-init/ce-node-aws.multipart.tpl 'mcn_smsv2_software_version=${software_version}'
require_text terraform/cloud-init/ce-node-aws.multipart.tpl 'mcn_smsv2_os_version=${os_version}'
require_text terraform/cloud-init/ce-node-aws.multipart.tpl '/var/home/admin/.ssh/authorized_keys'
require_text terraform/cloud-init/ce-node-aws.multipart.tpl 'nmcli connection modify "$connection" ipv4.never-default yes ipv6.never-default yes'
require_text terraform/cloud-init/ce-node-aws.multipart.tpl 'systemctl try-restart vpm.service'
reject_text terraform/cloud-init/ce-node-aws.multipart.tpl '/etc/vpm/'
require_text terraform/aws_vpc.tf 'resource "aws_vpc" "workload"'
require_text terraform/aws_vpc.tf 'resource "aws_instance" "workload"'
require_text terraform/aws_vpc.tf 'iam_instance_profile        = aws_iam_instance_profile.workload[0].name'
require_text terraform/aws_xc.tf 'public_name { dns_name = var.aws_origin_dns_name }'
reject_text terraform/aws_vpc.tf 'resource "aws_instance" "origin"'
reject_text terraform/aws_vpc.tf 'resource "aws_security_group" "origin"'
reject_text terraform/aws_xc.tf 'aws_instance.origin[0].public_ip'
require_text terraform/aws_vpc.tf 'resource "aws_ec2_transit_gateway_vpc_attachment" "workload"'
require_text terraform/aws_vpc.tf 'resource "aws_lb" "smsv2" {'
require_text terraform/aws_vpc.tf '#checkov:skip=CKV2_AWS_20:Internal TCP NLB; HTTP redirects are an ALB listener capability.'
require_text terraform/aws_vpc.tf 'private_ipv4_address = var.aws_vip'
require_text terraform/aws_vpc.tf 'resource "aws_lb_target_group" "smsv2" {'
require_text terraform/aws_vpc.tf 'target_type = "ip"'
require_text terraform/aws_vpc.tf 'resource "aws_lb_target_group_attachment" "smsv2" {'
require_text terraform/aws_vpc.tf 'target_id         = each.value.listener_ip'
require_text terraform/aws_vpc.tf 'availability_zone = "all"'
require_text terraform/aws_vpc.tf 'resource "aws_lb_listener" "smsv2" {'
require_text terraform/aws_vpc.tf 'for_each = var.enable_aws_tgw_connect ? toset([for site in values(local.aws_sites) : site.listener_ip]) : toset([])'
for route_table in public private; do
  route_table_body=$(sed -n "/resource \"aws_route_table\" \"${route_table}\" {/,/^}/p" terraform/aws_vpc.tf)
  grep -Fq 'depends_on = [module.aws_tgw_connect]' <<<"$route_table_body" || {
    printf '%s route table must wait for the complete TGW transport module\n' "$route_table" >&2
    exit 1
  }
done
require_text scripts/aws-smsv2-uat-preflight.sh 'site_listener_tgw_route_unavailable'
require_text scripts/aws-smsv2-uat-preflight.sh 'failed_site_target_did_not_withdraw'
require_text scripts/aws-smsv2-uat-preflight.sh '--retry 12 --retry-all-errors --retry-delay 2 --retry-max-time 45'
reject_text scripts/aws-smsv2-uat-preflight.sh '--retry-delay 0'
require_text scripts/aws-smsv2-uat-preflight.sh '>> /var/tmp/${TRAFFIC_MARKER}.log 2>&1 & echo'
require_text scripts/aws-smsv2-uat-preflight.sh 'echo vip_ok'
require_text scripts/aws-smsv2-uat-preflight.sh 'echo vip_fail'
require_text scripts/aws-smsv2-uat-preflight.sh 'echo origin_ok'
require_text scripts/aws-smsv2-uat-preflight.sh 'echo origin_fail'
require_text scripts/aws-smsv2-uat-preflight.sh 'aws_origin_dns_name'
require_text scripts/aws-smsv2-uat-preflight.sh 'origin_control_failures:$origin_control_failures'
require_text scripts/aws-smsv2-uat-preflight.sh '[ "$VIP_FAILED" -ne 0 ]'
require_text scripts/aws-smsv2-uat-preflight.sh 'block_traffic ssm_vip_retry_window_exhausted'
reject_text scripts/aws-smsv2-uat-preflight.sh 'aws_baseline_'
reject_text scripts/aws-smsv2-uat-preflight.sh 'aws_target_'
reject_text scripts/aws-smsv2-uat-preflight.sh 'continuity-only'
require_text scripts/aws-smsv2-uat-preflight.sh 'configured_version_convergence_failed'
require_text scripts/aws-smsv2-uat-preflight.sh 'final_refresh_plan_has_resource_changes'
require_text scripts/aws-smsv2-uat-preflight.sh 'final_refresh_apply_failed'
require_text scripts/aws-smsv2-uat-preflight.sh '--candidate-provider-binary'
require_text scripts/aws-smsv2-uat-preflight.sh '--candidate-provider-sha256'
require_text scripts/aws-smsv2-uat-preflight.sh 'provider_sha256'
require_text scripts/aws-smsv2-owned-collision-preflight.sh 'unowned or ambiguous AWS collision'
require_text scripts/aws-smsv2-owned-collision-preflight.sh 'unowned or ambiguous F5 collision'
require_text docs/en/demo/deploy.mdx 'aws-smsv2-owned-collision-preflight.sh'
require_text docs/en/demo/deploy.mdx '--candidate-provider-binary'
require_text docs/en/demo/deploy.mdx 'terraform-provider-xcsh'
require_text terraform/aws_upgrade.tf 'action "xcsh_site_upgrade_sw" "aws"'
require_text terraform/aws_upgrade.tf 'software_version = coalesce(var.aws_upgrade_software_version, var.aws_software_version)'
require_text terraform/aws_upgrade.tf 'os_version = coalesce(var.aws_upgrade_os_version, var.aws_os_version)'
require_text terraform/aws_upgrade.tf 'expected_software_version = coalesce(var.aws_upgrade_software_version, var.aws_software_version)'
require_text terraform/aws_upgrade.tf 'expected_os_version       = coalesce(var.aws_upgrade_os_version, var.aws_os_version)'
require_text terraform/aws_upgrade.tf 'action "xcsh_site_upgrade_os" "aws"'
require_text terraform/aws_upgrade.tf 'data "xcsh_site_upgrade_status" "aws"'
sw_action=$(sed -n '/action "xcsh_site_upgrade_sw" "aws" {/,/^}/p' terraform/aws_upgrade.tf)
grep -Fq 'site             = each.value.name' <<<"$sw_action" || {
  printf 'software upgrade action must use the v11 site field\n' >&2
  exit 1
}
grep -Fq 'software_version = coalesce(var.aws_upgrade_software_version, var.aws_software_version)' <<<"$sw_action" || {
  printf 'software upgrade action must use its independent target field\n' >&2
  exit 1
}
os_action=$(sed -n '/action "xcsh_site_upgrade_os" "aws" {/,/^}/p' terraform/aws_upgrade.tf)
grep -Fq 'site       = each.value.name' <<<"$os_action" || {
  printf 'OS upgrade action must use the v11 site field\n' >&2
  exit 1
}
grep -Fq 'os_version = coalesce(var.aws_upgrade_os_version, var.aws_os_version)' <<<"$os_action" || {
  printf 'OS upgrade action must use its independent target field\n' >&2
  exit 1
}
reject_text terraform/aws_upgrade.tf 'namespace                 = "system"'
require_text terraform/aws_upgrade.tf 'output "aws_site_upgrade_status"'
require_text terraform/aws_upgrade.tf 'target_converged'
require_text terraform/variables_aws.tf 'variable "aws_software_version"'
require_text terraform/variables_aws.tf 'variable "aws_os_version"'
require_text terraform/variables_aws.tf 'variable "aws_upgrade_software_version"'
require_text terraform/variables_aws.tf 'variable "aws_upgrade_os_version"'
require_text terraform/variables_aws.tf 'default     = "crt-20260201-0179"'
require_text terraform/variables_aws.tf 'default     = "9.2026.17"'
reject_text terraform/variables_aws.tf 'variable "aws_baseline_software_version"'
reject_text terraform/variables_aws.tf 'variable "aws_baseline_os_version"'
require_text terraform/variables_aws.tf 'default     = "10.151.0.0/16"'
require_text terraform/variables_aws.tf 'default     = "10.151.1.10"'
require_text terraform/aws_ce.tf 'depends_on = [aws_internet_gateway.aws]'
require_text terraform/variables_aws.tf 'variable "aws_bootstrap_site_keys"'
require_text terraform/variables_aws.tf 'default     = ["01", "02", "03"]'

workload_sg=$(sed -n '/resource "aws_security_group" "workload" {/,/^}/p' "${REPO_ROOT}/terraform/aws_vpc.tf")
if grep -Eq '^[[:space:]]*ingress[[:space:]]*{' <<<"$workload_sg"; then
  printf 'workload SSM client security group must not declare ingress\n' >&2
  exit 1
fi
if grep -Fq 'protocol    = "-1"' <<<"$workload_sg"; then
  printf 'workload SSM client security group must not allow unrestricted egress\n' >&2
  exit 1
fi

printf 'PASS: AWS three-site upgrade showcase contract\n'
