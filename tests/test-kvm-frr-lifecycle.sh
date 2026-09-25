#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
kvm="$repo_root/terraform/kvm.tf"
module_kvm="$repo_root/terraform/modules/kvm/kvm.tf"
frr="$repo_root/terraform/kvm_frr.tf"
module_frr="$repo_root/terraform/modules/kvm/kvm_frr.tf"
onprem="$repo_root/terraform/onprem_kvm.tf"
outputs="$repo_root/terraform/outputs.tf"
locals="$repo_root/terraform/locals.tf"
module_onprem="$repo_root/terraform/modules/kvm/onprem_kvm.tf"
module_locals="$repo_root/terraform/modules/kvm/locals.tf"
workload="$repo_root/terraform/onprem_workload.tf"
variables="$repo_root/terraform/variables.tf"
observer="$repo_root/terraform/scripts/xc-kvm-bgp-observer.py"
plan_scope="$repo_root/scripts/kvm-lan-plan-scope.py"
lifecycle="$repo_root/scripts/showcase-lifecycle.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}
require() { grep -Fq "$1" "$2" || fail "missing $1 in $2"; }
reject() { ! grep -Fq "$1" "$2" || fail "unexpected $1 in $2"; }
reject_exact() { ! grep -Fxq "$1" "$2" || fail "unexpected exact line $1 in $2"; }

require 'kvm_ce_nodes' "$kvm"
require 'kvm_enabled_nodes' "$kvm"
require 'count = var.enable_kvm ? 1 : 0' "$kvm"
require 'kvm_network_generation' "$kvm"
require 'kvm_network_name' "$kvm"
require 'kvm_network_bridge' "$kvm"
require 'local.kvm_bootstrap_generation}-disk.qcow2' "$kvm"
require 'local.kvm_bootstrap_generation}-cloudinit.iso' "$kvm"
require 'kvm_bootstrap_generation' "$kvm"
require '"{{ .token }}"' "$kvm"
require 'xcsh_token.kvm[0].uid' "$kvm"
require 'data "xcsh_site_image" "kvm"' "$kvm"
require 'provider_ref              = "kvm"' "$kvm"
[ "$(grep -Ec 'site_name[[:space:]]*=[[:space:]]*local\.kvm_site_name' "$kvm")" -eq 4 ] ||
  fail 'active KVM lookups must use the stable canonical site name in both phases'
[ "$(grep -Ec 'depends_on[[:space:]]*=[[:space:]]*\[xcsh_securemesh_site_v2\.onprem_kvm\]' "$kvm")" -eq 2 ] ||
  fail 'active KVM bootstrap lookups must retain explicit site creation ordering'
require 'data "xcsh_site_image" "kvm_configured"' "$kvm"
require 'data "xcsh_site_cloud_init" "kvm_configured"' "$kvm"
require 'data.xcsh_site_image.kvm_configured[0]' "$kvm"
require 'data.xcsh_site_cloud_init.kvm_configured[0]' "$kvm"
[ "$(grep -Ec 'site_name[[:space:]]*=[[:space:]]*local\.kvm_site_name' "$module_kvm")" -eq 4 ] ||
  fail 'module KVM lookups must use the stable canonical site name in both phases'
[ "$(grep -Ec 'depends_on[[:space:]]*=[[:space:]]*\[xcsh_securemesh_site_v2\.onprem_kvm\]' "$module_kvm")" -eq 2 ] ||
  fail 'module KVM bootstrap lookups must retain explicit site creation ordering'
require 'data "xcsh_site_image" "kvm_configured"' "$module_kvm"
require 'data "xcsh_site_cloud_init" "kvm_configured"' "$module_kvm"
require 'resource "terraform_data" "kvm_ce_image_cache"' "$kvm"
require 'triggers_replace = [local.kvm_site_image.image_md5_sum]' "$kvm"
reject 'triggers_replace = [data.xcsh_site_image.kvm[0].image_download_url' "$kvm"
require 'triggers_replace = [local.kvm_site_image.image_md5_sum]' "$module_kvm"
reject 'triggers_replace = [data.xcsh_site_image.kvm[0].image_download_url' "$module_kvm"
require 'resource "libvirt_pool" "kvm"' "$kvm"
require 'md5:$IMAGE_MD5' "$kvm"
require 'libvirt_pool.kvm[0].name' "$kvm"
reject 'base-cloud-noble.qcow2' "$kvm"
require '10.100.0.11' "$kvm"
require '10.100.0.100' "$kvm"
require 'mac            = each.value.mac' "$kvm"
require 'enabled = true' "$kvm"
require 'local_only = true' "$kvm"
require 'local_only = true' "$module_kvm"
require 'option_name  = "dhcp-host"' "$kvm"
require 'option_value = "${options.value.mac},${options.value.address}"' "$kvm"
require 'resource "terraform_data" "kvm_network_identity"' "$kvm"
require 'replace_triggered_by = [terraform_data.kvm_network_identity[0]]' "$kvm"
require 'kvm_token_labels = {' "$locals"
require 'if key != "mcn-source-commit"' "$locals"
require 'kvm_token_labels = {' "$module_locals"
require 'if key != "mcn-source-commit"' "$module_locals"
root_token=$(sed -n '/resource "xcsh_token" "kvm"/,/^}/p' "$onprem")
module_token=$(sed -n '/resource "xcsh_token" "kvm"/,/^}/p' "$module_onprem")
grep -Fq 'labels      = local.kvm_token_labels' <<<"$root_token" ||
  fail 'root KVM token must use stable deployment labels'
grep -Fq 'labels      = local.kvm_token_labels' <<<"$module_token" ||
  fail 'module KVM token must use stable deployment labels'
reject 'network_config' "$kvm"
reject '/etc/netplan/60-mcn-ce-static.yaml' "$kvm"
require 'libvirt_cloudinit_disk.ce_cloudinit[each.key]' "$kvm"
require 'libvirt_network.ce_bgp_net' "$kvm"
require 'resource "terraform_data" "kvm_workload_image_cache"' "$workload"
require 'sha512:$IMAGE_SHA512' "$workload"
require 'network_config = yamlencode({' "$workload"
require 'match    = { macaddress = local.kvm_workload_node.mac }' "$workload"
require 'dhcp4    = true' "$workload"
require 'match     = { macaddress = local.kvm_workload_lan_mac }' "$workload"
require 'resource "libvirt_domain" "workload"' "$workload"
require 'wait_for_lease = true' "$workload"
require 'mode = "host-passthrough"' "$workload"
require 'target_type = "serial"' "$workload"
require 'target_port = "0"' "$workload"
require 'qemu-guest-agent' "$workload"

require 'resource "docker_container" "kvm_frr"' "$frr"
require 'count = var.enable_kvm ? 1 : 0' "$frr"
require 'mcn-kvm-frr-router' "$frr"
require 'log_opts' "$frr"
require '"max-file" = "3"' "$frr"
require '"max-size" = "10m"' "$frr"
require 'ulimit {' "$frr"
require 'name = "nofile"' "$frr"
require 'hard = 65536' "$frr"
require 'soft = 65536' "$frr"
require 'log_opts' "$module_frr"
require '"max-file" = "3"' "$module_frr"
require '"max-size" = "10m"' "$module_frr"
require 'ulimit {' "$module_frr"
require 'name = "nofile"' "$module_frr"
require 'hard = 65536' "$module_frr"
require 'soft = 65536' "$module_frr"
require 'driver = "macvlan"' "$frr"
require 'parent = local.kvm_network_bridge' "$frr"
require 'ipv4_address = "10.100.0.2"' "$frr"
require 'frrouting/frr@sha256:990e83490108b686fd6df3b1cafa6bdbb2714acb00eedb9a89693946f46f45ce' "$frr"
require 'neighbor ${node.address} remote-as 64512' "$frr"
require 'maximum-paths 4' "$frr"
require 'depends_on = [libvirt_network.ce_bgp_net]' "$frr"
reject '/data/services/frr-router' "$frr"
reject 'name = "frr-router"' "$frr"
require 'address = "10.100.0.2"' "$onprem"
require 'count = var.enable_kvm ? 1 : 0' "$onprem"
require 'replace_triggered_by = [xcsh_securemesh_site_v2.onprem_kvm[0].id]' "$onprem"
[ "$(grep -Fc 'replace_triggered_by = [xcsh_securemesh_site_v2.onprem_kvm[0].id]' "$onprem")" -eq 2 ] ||
  fail 'KVM token and BGP replacement triggers must both follow site identity only'
reject_exact '    replace_triggered_by = [xcsh_securemesh_site_v2.onprem_kvm[0]]' "$onprem"
require 'disable_ha                 = {}' "$onprem"
reject 'enable_ha                  = {}' "$onprem"
reject 'dynamic "node_list"' "$onprem"
require 'data "xcsh_smsv2_kvm_runtime" "kvm_slo"' "$onprem"
require 'expected_mac          = local.kvm_ce_nodes["01"].mac' "$onprem"
require 'data.xcsh_smsv2_kvm_runtime.kvm_slo[0].interface_name' "$onprem"
require 'data "xcsh_smsv2_kvm_runtime" "kvm_slo"' "$module_onprem"
require 'data.xcsh_smsv2_kvm_runtime.kvm_slo[0].interface_name' "$module_onprem"
reject 'name      = "eth0"' "$module_onprem"
require 'resource "xcsh_smsv2_kvm_runtime_interface" "kvm_lan_sli"' "$onprem"
require 'site         = local.kvm_site_name' "$onprem"
require 'expected_mac = var.kvm_lan.sli_mac' "$onprem"
require 'ipv4_cidr    = var.kvm_lan.sli_cidr' "$onprem"
require 'observed_sli       = try(xcsh_smsv2_kvm_runtime_interface.kvm_lan_sli["sli"].device, null)' "$outputs"
require 'realized_sli       = try(xcsh_smsv2_kvm_runtime_interface.kvm_lan_sli["sli"].device, null)' "$outputs"
reject 'realized_sli       = try(xcsh_smsv2_kvm_runtime_interface.kvm_lan_sli["sli"].interface_name, null)' "$outputs"
reject 'resource "xcsh_network_interface"' "$onprem"
reject 'import {' "$onprem"
reject 'var.kvm_lan_observed_node' "$onprem"
require 'docker_container.kvm_frr' "$onprem"
require 'libvirt_domain.ce_node' "$onprem"
reject 'data "external" "kvm_network_interface"' "$onprem"
reject 'data "external" "kvm_lan_network_interface"' "$onprem"
reject 'xc-kvm-network-interface.py' "$onprem"
require 'data "external" "kvm_bgp_observer"' "$onprem"
require 'expected_peer_address   = try(local.kvm_expected_bgp_peers["node_01_slo"].peer_address, "")' "$onprem"
require 'expected_imported_route = try(one(local.kvm_expected_bgp_peers["node_01_slo"].expected_imported_routes), "")' "$onprem"
reject 'expected_exported_routes = []' "$onprem"
reject 'name      = "eth0"' "$onprem"
test ! -e "$repo_root/terraform/scripts/xc-kvm-network-interface.py" ||
  fail 'legacy external KVM interface resolver must be removed'
test ! -e "$repo_root/tests/test_xc_kvm_network_interface.py" ||
  fail 'legacy external KVM interface resolver tests must be removed'
require 'mcn.kvm-lan-preflight/v2' "$plan_scope"
require 'hardware plan must create or replace the KVM domain' "$plan_scope"
require 'configured plan is missing the owned SLI/application actions' "$plan_scope"
require 'configured plan must adopt the owned KVM SLI interface through one create action' "$plan_scope"
require 'terraform -chdir="$TERRAFORM_DIR" show -json "$KVM_LAN_PLAN"' "$lifecycle"
require 'hmac.compare_digest(' "$observer"
require 'expected BGP peer state is' "$observer"
require 'expected imported route has no path from the exact BGP peer' "$observer"
require 'variable "enable_kvm"' "$variables"
require 'no KVM image lookup occurs while disabled' "$variables"

python3 "$repo_root/tests/test_xc_kvm_bgp_observer.py"
python3 "$repo_root/tests/test_kvm_lan_plan_scope.py"

printf 'PASS: KVM CE identity and FRR lifecycle are Terraform-owned\n'
