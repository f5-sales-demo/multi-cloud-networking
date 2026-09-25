#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

for region in '' '_ca'; do
  block=$(sed -n "/module \"azure_hub${region}\" {/,/^}/p" terraform/main.tf)
  grep -Fq 'enable_route_server        = var.enable_bgp' <<<"$block"
done

grep -Fq 'module "azure_frr_us" {' terraform/main.tf
grep -Fq 'module "azure_frr_ca" {' terraform/main.tf
if grep -Fq 'module "azure_route_server_bgp" {' terraform/main.tf; then exit 1; fi
if grep -Fq 'module "azure_route_server_bgp_ca" {' terraform/main.tf; then exit 1; fi
if grep -Fq 'azure_route_server_ebgp_multihop' terraform/main.tf; then exit 1; fi

for ilb in terraform/azure_ilb.tf terraform/ca_ilb.tf; do
  grep -Fq 'name                          = "application-frontend"' "$ilb"
  grep -Fq 'name                          = "console-frontend"' "$ilb"
  grep -Fq 'name                           = "application-rule"' "$ilb"
  grep -Fq 'name                           = "console-rule"' "$ilb"
  grep -Fq 'floating_ip_enabled            = true' "$ilb"
  grep -Fq 'floating_ip_enabled            = false' "$ilb"
  grep -Fq '.internal_nic_id' "$ilb"
done

grep -Fq 'SITE_NETWORK_SPECIFIED_VIP_INSIDE' terraform/modules/azure-ilb-app/main.tf
grep -Fq 'domain           = "ilb.${local.lb_domain}"' terraform/azure_ilb_xc.tf
grep -Fq 'domain           = "ilb.${local.ca_lb_domain}"' terraform/azure_ilb_xc.tf
echo 'PASS: Azure dual-path relay and ILB contract'
