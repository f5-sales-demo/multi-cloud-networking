#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

check() { grep -Eq -- "$1" "$2" || {
  echo "missing $1 in $2" >&2
  exit 1
}; }
reject() { if grep -Eq -- "$1" "$2"; then
  echo "obsolete $1 in $2" >&2
  exit 1
fi; }

check 'version = "= 12\.0\.3"' terraform/versions.tf
check 'xcsh_network_customer_edge_egress' terraform/data.tf
check 'module "azure_frr_us"' terraform/main.tf
check 'module "azure_frr_ca"' terraform/main.tf
reject 'module "azure_route_server_bgp"' terraform/main.tf
reject 'module "azure_route_server_bgp_ca"' terraform/main.tf
reject 'azure_route_server_ebgp_multihop' terraform/main.tf
check 'Microsoft.Network/virtualHubs/bgpConnections@2022-01-01' terraform/modules/azure-frr/main.tf
check 'depends_on = \[azapi_resource.route_server_primary\]' terraform/modules/azure-frr/main.tf
check 'ip_forwarding_enabled[[:space:]]*=[[:space:]]*true' terraform/modules/azure-frr/main.tf
check 'ip prefix-list VIP seq 10 permit' terraform/modules/azure-frr/cloud-init.yaml.tftpl
check 'route-map RS-OUT permit' terraform/modules/azure-frr/cloud-init.yaml.tftpl
reject 'permit 0\.0\.0\.0/0 le 32' terraform/modules/azure-frr/cloud-init.yaml.tftpl

for region in azure ca; do
  ilb="terraform/${region}_ilb.tf"
  check 'application-frontend' "$ilb"
  check 'console-frontend' "$ilb"
  check 'application-rule' "$ilb"
  check 'console-rule' "$ilb"
  check 'floating_ip_enabled[[:space:]]*=[[:space:]]*false' "$ilb"
  check 'internal_nic_id' "$ilb"
done

check 'network_interface' terraform/kvm.tf
check 'xcsh_smsv2_kvm_runtime_interface' terraform/onprem_kvm.tf
check 'SITE_NETWORK_SPECIFIED_VIP_INSIDE' terraform/kvm_lan.tf
check 'azure=var.enable_azure' scripts/showcase-lifecycle.sh
check 'kvm_lan=var.enable_kvm_lan' scripts/showcase-lifecycle.sh
check 'scope_plan zero-change' scripts/showcase-lifecycle.sh
check 'apply_scoped_plan azure-build' scripts/showcase-lifecycle.sh
check 'az account show --subscription' scripts/showcase-lifecycle.sh
check 'default_route_table_association[[:space:]]*=[[:space:]]*"enable"' terraform/modules/aws-tgw-connect/main.tf
check 'transit_gateway_default_route_table_association[[:space:]]*=[[:space:]]*true' terraform/modules/aws-tgw-connect/main.tf
check 'value[[:space:]]*=[[:space:]]*aws_ec2_transit_gateway.this.association_default_route_table_id' terraform/modules/aws-tgw-connect/outputs.tf
check 'transit_gateway_default_route_table_association[[:space:]]*=[[:space:]]*true' terraform/aws_vpc.tf
reject 'resource "aws_ec2_transit_gateway_route_table_association"' terraform/modules/aws-tgw-connect/main.tf
reject 'resource "aws_ec2_transit_gateway_route_table_association"' terraform/aws_vpc.tf
echo 'PASS: complete showcase graph contract'

check 'mcn-topology in' terraform/kvm_lan.tf
check 'mcn-topology in' terraform/modules/azure-ilb-app/main.tf
reject 'ves.io/siteName' terraform/kvm_lan.tf
reject 'ves.io/siteName' terraform/modules/azure-ilb-app/main.tf
reject 'ves.io/siteName' terraform/main.tf

check 'resource "random_uuid" "generation"' terraform/modules/ce-node/main.tf
reject 'azurerm_linux_virtual_machine' terraform/modules/ce-node/main.tf
check 'replace_triggered_by = \[terraform_data.generation\]' terraform/modules/ce-vm/main.tf
check 'ce_generation_id[[:space:]]*=[[:space:]]*module.ce_node\[each.key\].generation_id' terraform/main.tf
check 'depends_on[[:space:]]*= \[module.xc_site\]' terraform/main.tf
reject 'ce_vm_instance_id[[:space:]]*=[[:space:]]*module.ce_node' terraform/main.tf

check 'labels[[:space:]]*=[[:space:]]*local.azure_token_labels' terraform/main.tf
check 'azure_token_labels' terraform/locals.tf

check 'mcn-frr-bootstrap.service' terraform/modules/azure-frr/cloud-init.yaml.tftpl

check 'azure_site_configuration_phase=bootstrap' scripts/showcase-lifecycle.sh
check 'bind_azure_interfaces' scripts/showcase-lifecycle.sh
check 'inside_nic_mac' terraform/modules/xc-site/main.tf
