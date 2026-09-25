#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

check() { grep -Eq -- "$1" "$2" || { echo "missing $1 in $2" >&2; exit 1; }; }
reject() { if grep -Eq -- "$1" "$2"; then echo "obsolete $1 in $2" >&2; exit 1; fi; }

check 'version = "= 11\.3\.0"' terraform/versions.tf
check 'xcsh_network_customer_edge_egress' terraform/data.tf
check 'module "azure_frr_us"' terraform/main.tf
check 'module "azure_frr_ca"' terraform/main.tf
reject 'module "azure_route_server_bgp"' terraform/main.tf
reject 'module "azure_route_server_bgp_ca"' terraform/main.tf
reject 'azure_route_server_ebgp_multihop' terraform/main.tf
check 'azurerm_route_server_bgp_connection' terraform/modules/azure-frr/main.tf
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
echo 'PASS: complete showcase graph contract'
