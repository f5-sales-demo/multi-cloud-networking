#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

for region in '' '_ca'; do
  block=$(sed -n "/module \"azure_hub${region}\" {/,/^}/p" terraform/main.tf)
  grep -Fq 'enable_route_server        = var.enable_bgp' <<<"$block"
done

grep -Eq 'count[[:space:]]*=[[:space:]]*var\.enable_route_server \? 1 : 0' terraform/modules/azure-hub/main.tf
grep -Fq 'for_each = var.enable_azure && var.enable_bgp ? module.ce_topology.ce_nodes : {}' terraform/main.tf
grep -Fq 'for_each = var.enable_bgp ? try(module.ce_topology_ca[0].ce_nodes, {}) : {}' terraform/main.tf
grep -Fq 'resource "azurerm_lb" "azure_ilb"' terraform/azure_ilb.tf
grep -Fq 'resource "azurerm_lb" "ca_ilb"' terraform/ca_ilb.tf
grep -Fq 'required_capabilities = var.enable_azure && var.enable_bgp ? ["azure_route_server_ebgp_multihop"] : []' terraform/main.tf
grep -Fq 'Azure Route Server remains deferred' docs/en/demo/index.mdx

echo 'PASS: Azure ILB showcase omits Route Server unless the fail-closed BGP option is requested'
