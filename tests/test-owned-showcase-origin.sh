#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
grep -q 'module "showcase_origin"' "$repo/terraform/azure_origin.tf"
grep -Eq 'ip[[:space:]]*=[[:space:]]*local.selected_origin_ip' "$repo/terraform/main.tf"
grep -Eq 'value[[:space:]]*=[[:space:]]*local.selected_origin_ip' "$repo/terraform/outputs.tf"
grep -q 'var.serve_http' "$repo/terraform/modules/client-vm/main.tf"
grep -q 'mcn-showcase-origin' "$repo/terraform/azure_origin.tf"
grep -Eq 'private_ip[[:space:]]*=[[:space:]]*cidrhost\(var.mgmt_subnet_prefix, 30\)' "$repo/terraform/azure_origin.tf"
grep -q 'module "showcase_origin_ca"' "$repo/terraform/azure_origin.tf"
grep -Eq 'ip[[:space:]]*=[[:space:]]*local.selected_ca_origin_ip' "$repo/terraform/main.tf"
grep -Eq 'resource_group_name[[:space:]]*=[[:space:]]*module.azure_hub_ca\[0\].resource_group_name' "$repo/terraform/azure_origin.tf"
grep -q 'mcn-showcase-canada-origin' "$repo/terraform/azure_origin.tf"
grep -Eq 'private_ip[[:space:]]*=[[:space:]]*cidrhost\(var.ca_mgmt_subnet_prefix, 30\)' "$repo/terraform/azure_origin.tf"
grep -Eq 'subnet_id[[:space:]]*=[[:space:]]*module.azure_hub_ca\[0\].management_subnet_id' "$repo/terraform/azure_origin.tf"
echo 'PASS: regional origins are owned and selected for their pools and controls'
